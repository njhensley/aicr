// Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"

	"github.com/NVIDIA/aicr/pkg/defaults"
	aicrErrors "github.com/NVIDIA/aicr/pkg/errors"
	k8spod "github.com/NVIDIA/aicr/pkg/k8s/pod"
	"github.com/NVIDIA/aicr/pkg/recipe"
	"github.com/NVIDIA/aicr/validators"
)

// grdmaPciTopoCheckOverrideRe matches the runtime-parameter line the NVIDIA
// kernel module writes to /proc/driver/nvidia/params when
// NVreg_GrdmaPciTopoCheckOverride=1 is set on driver load. Anchored to a
// full line so a commented-out default like "# GrdmaPciTopoCheckOverride: 0"
// would not match. Shared between the per-node probe Pod's grep argument
// (as a plain string) and parseNVregFromParams() for unit testing.
var grdmaPciTopoCheckOverrideRe = regexp.MustCompile(`(?m)^GrdmaPciTopoCheckOverride: 1$`)

// parseNVregFromParams reports whether /proc/driver/nvidia/params content has
// NVreg_GrdmaPciTopoCheckOverride set to 1. Pure function for unit testing;
// the pod-based check uses grep with the same pattern.
func parseNVregFromParams(content string) bool {
	return grdmaPciTopoCheckOverrideRe.MatchString(content)
}

const (
	// preflightPodTimeout bounds how long we wait for the check pod to
	// schedule, run, and terminate. The actual work is one grep.
	preflightPodTimeout = 2 * time.Minute

	// preflightPodNamePrefix is the generateName seed for the per-node probe
	// pods. Short so the full name (including node hash + rand suffix) fits
	// inside the 63-character DNS-1123 label limit on all realistic node
	// names.
	preflightPodNamePrefix = "nccl-nvreg-probe-"

	// nvregDocsHint is the cluster-operator-facing message the preflight
	// emits when the flag is missing. Keeps the fix one `kubectl` away.
	nvregDocsHint = `NVreg_GrdmaPciTopoCheckOverride=1 is required on p6e-gb200 EKS nodes so ` +
		`the NVIDIA driver allows EFA (a PCIe-attached NIC) to attach dma-buf ` +
		`handles for GPU HBM on the Grace CPU topology. Without it, the kernel ` +
		`rejects the attach with "NVRM: dma-buf attach failed: topology not ` +
		`supported for mapping type FORCE_PCIE" and NCCL silently falls back ` +
		`to the Socket transport. Set it via the GPU Operator ClusterPolicy: ` +
		`spec.driver.kernelModuleConfig.name → a ConfigMap in gpu-operator ` +
		`with data "nvidia.conf: options nvidia NVreg_GrdmaPciTopoCheckOverride=1", ` +
		`then delete the nvidia-driver DaemonSet pods to pick up the change.`
)

// preflightGB200NetNVregFlag verifies that every target GPU node has the
// NVIDIA kernel driver loaded with NVreg_GrdmaPciTopoCheckOverride=1. Called
// only for the NET variant on GB200/EKS — this is the knob that determines
// whether EFA GPUDirect RDMA works on the GB200 PCI topology. NVLS (MNNVL)
// traffic stays on NVLink-C2C and does not need it.
//
// The check runs one short-lived Pod per target node, pinned via NodeName,
// with /proc/driver/nvidia hostPath-mounted read-only. The pod greps for the
// parameter line and exits 0 if found, non-zero if missing. The validator
// consolidates per-node results into a single error so operators see every
// misconfigured node at once rather than one-at-a-time.
func preflightGB200NetNVregFlag(ctx *validators.Context, nodes []corev1.Node) error {
	if len(nodes) == 0 {
		return aicrErrors.New(aicrErrors.ErrCodeInvalidRequest,
			"preflight called with no target nodes")
	}

	slog.Info("NET preflight: checking NVreg_GrdmaPciTopoCheckOverride on GPU nodes",
		"nodes", len(nodes))

	var missing []string
	for _, n := range nodes {
		ok, err := checkNVregOnNode(ctx, n.Name)
		if err != nil {
			return aicrErrors.WrapWithContext(aicrErrors.ErrCodeInternal,
				"NVreg preflight probe failed", err,
				map[string]interface{}{"node": n.Name})
		}
		if !ok {
			missing = append(missing, n.Name)
		}
	}

	if len(missing) > 0 {
		return aicrErrors.New(aicrErrors.ErrCodeInvalidRequest,
			fmt.Sprintf("NVreg_GrdmaPciTopoCheckOverride=1 missing on GPU nodes: %s. %s",
				strings.Join(missing, ", "), nvregDocsHint))
	}

	slog.Info("NET preflight passed: NVreg_GrdmaPciTopoCheckOverride=1 on all target nodes",
		"nodes", len(nodes))
	return nil
}

// checkNVregOnNode creates and waits on a short-lived probe pod that reads
// /proc/driver/nvidia/params on a specific node. Returns (true, nil) if the
// flag is set, (false, nil) if the flag is absent or zero, or (_, err) on
// any other failure (pod schedule, image pull, log read).
func checkNVregOnNode(ctx *validators.Context, nodeName string) (bool, error) {
	podsClient := ctx.Clientset.CoreV1().Pods(ctx.Namespace)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: preflightPodNamePrefix,
			Namespace:    ctx.Namespace,
			Labels: map[string]string{
				"app.kubernetes.io/component":  "nccl-nvreg-preflight",
				"app.kubernetes.io/managed-by": "aicr-validator",
			},
		},
		Spec: corev1.PodSpec{
			NodeName:      nodeName,
			RestartPolicy: corev1.RestartPolicyNever,
			// Tolerate whatever taints the GPU nodes carry. The preflight
			// is cheap (busybox + grep) so we accept wherever scheduler
			// places us on the target node.
			Tolerations: []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
			Containers: []corev1.Container{{
				Name:    "probe",
				Image:   defaults.ProbeImage,
				Command: []string{"/bin/sh", "-c"},
				// grep -q is silent; the exit code carries the signal. Use a
				// plain grep fallback (no -q) to emit the matching line to
				// stdout when present — useful when an operator runs the
				// validator with --verbose and wants confirmation.
				Args: []string{
					"grep '^GrdmaPciTopoCheckOverride: 1$' /host-proc-nvidia/params",
				},
				VolumeMounts: []corev1.VolumeMount{{
					Name:      "proc-nvidia",
					MountPath: "/host-proc-nvidia",
					ReadOnly:  true,
				}},
			}},
			Volumes: []corev1.Volume{{
				Name: "proc-nvidia",
				VolumeSource: corev1.VolumeSource{
					HostPath: &corev1.HostPathVolumeSource{
						Path: "/proc/driver/nvidia",
					},
				},
			}},
		},
	}

	created, err := podsClient.Create(ctx.Ctx, pod, metav1.CreateOptions{})
	if err != nil {
		return false, aicrErrors.Wrap(aicrErrors.ErrCodeInternal,
			"failed to create NVreg preflight pod", err)
	}
	// Cleanup at function exit. Non-fatal if it races with test teardown.
	defer func() {
		if delErr := podsClient.Delete(ctx.Ctx, created.Name, metav1.DeleteOptions{}); delErr != nil && !apierrors.IsNotFound(delErr) {
			slog.Warn("failed to delete NVreg preflight pod", "pod", created.Name, "err", delErr)
		}
	}()

	var finalPhase corev1.PodPhase
	err = wait.PollUntilContextTimeout(ctx.Ctx, 2*time.Second, preflightPodTimeout, true,
		func(pctx context.Context) (bool, error) {
			p, getErr := podsClient.Get(pctx, created.Name, metav1.GetOptions{})
			if getErr != nil {
				return false, getErr
			}
			finalPhase = p.Status.Phase
			return finalPhase == corev1.PodSucceeded || finalPhase == corev1.PodFailed, nil
		})
	if err != nil {
		return false, aicrErrors.WrapWithContext(aicrErrors.ErrCodeTimeout,
			"NVreg preflight pod did not terminate in time", err,
			map[string]interface{}{"pod": created.Name, "phase": string(finalPhase)})
	}

	// Succeeded = grep matched = flag is set.
	if finalPhase == corev1.PodSucceeded {
		return true, nil
	}

	// Failed: distinguish flag-absent (grep exit 1) from harder errors by
	// fetching logs. Empty logs on Failed phase typically indicate the pod
	// never reached the grep — e.g. image pull failure or hostPath denied.
	logs, logErr := k8spod.GetPodLogs(ctx.Ctx, ctx.Clientset, ctx.Namespace, created.Name, "probe")
	if logErr != nil {
		return false, aicrErrors.Wrap(aicrErrors.ErrCodeInternal,
			"NVreg preflight pod Failed and logs were unreadable", logErr)
	}
	// grep with no match exits 1 and produces no output — the normal "flag
	// missing" path. Any stdout content means grep ran but matched nothing;
	// any non-empty stderr content would typically be e.g. "No such file or
	// directory" which means /proc/driver/nvidia was not populated (kernel
	// module not loaded at all — far more serious than a missing flag).
	if strings.TrimSpace(logs) != "" {
		slog.Warn("NVreg preflight pod emitted unexpected output",
			"node", nodeName, "output", strings.TrimSpace(logs))
	}
	return false, nil
}

// gb200NetPreflightApplies reports whether the preflight check should run for
// the given (variant, accelerator, service) tuple. Keeps the call site at the
// top of validateNcclAllReduceBw uncluttered.
func gb200NetPreflightApplies(variant ncclVariant, accelerator recipe.CriteriaAcceleratorType, service recipe.CriteriaServiceType) bool {
	return variant == variantNET &&
		accelerator == recipe.CriteriaAcceleratorGB200 &&
		service == recipe.CriteriaServiceEKS
}
