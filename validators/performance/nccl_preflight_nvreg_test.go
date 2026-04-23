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
	"testing"

	"github.com/NVIDIA/aicr/pkg/recipe"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestParseNVregFromParams(t *testing.T) {
	// Real /proc/driver/nvidia/params lines are "Name: <int>" per line.
	// The flag name in the file is the NVreg_ suffix without the prefix.
	paramsSet := `ModifyDeviceFiles: 1
GrdmaPciTopoCheckOverride: 1
EnablePCIeGen3: 0
`
	paramsDefault := `ModifyDeviceFiles: 1
EnablePCIeGen3: 0
`
	paramsExplicitZero := `ModifyDeviceFiles: 1
GrdmaPciTopoCheckOverride: 0
EnablePCIeGen3: 0
`
	paramsCommented := `ModifyDeviceFiles: 1
# GrdmaPciTopoCheckOverride: 1
EnablePCIeGen3: 0
`
	paramsSuffixMatch := `ModifyDeviceFiles: 1
MyCustomGrdmaPciTopoCheckOverride: 1
EnablePCIeGen3: 0
`

	tests := []struct {
		name    string
		content string
		want    bool
	}{
		{"flag set to 1", paramsSet, true},
		{"flag absent (driver default)", paramsDefault, false},
		{"flag explicitly 0", paramsExplicitZero, false},
		{"commented out (not active)", paramsCommented, false},
		{"different param name must not match as suffix", paramsSuffixMatch, false},
		{"empty file", "", false},
		{"just the flag line, no trailing newline", "GrdmaPciTopoCheckOverride: 1", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseNVregFromParams(tt.content); got != tt.want {
				t.Errorf("parseNVregFromParams() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGB200NetPreflightApplies(t *testing.T) {
	tests := []struct {
		name        string
		variant     ncclVariant
		accelerator recipe.CriteriaAcceleratorType
		service     recipe.CriteriaServiceType
		want        bool
	}{
		{
			"NET + GB200 + EKS → check required",
			variantNET, recipe.CriteriaAcceleratorGB200, recipe.CriteriaServiceEKS, true,
		},
		{
			"NVLS + GB200 + EKS → not required (NVLink-C2C, no PCIe dma-buf)",
			variantNVLS, recipe.CriteriaAcceleratorGB200, recipe.CriteriaServiceEKS, false,
		},
		{
			"default variant + GB200 + EKS → not required",
			variantDefault, recipe.CriteriaAcceleratorGB200, recipe.CriteriaServiceEKS, false,
		},
		{
			"NET + H100 + EKS → not required (H100 doesn't use Grace PCI topology)",
			variantNET, recipe.CriteriaAcceleratorH100, recipe.CriteriaServiceEKS, false,
		},
		{
			"NET + GB200 + GKE → not required (no EFA on GKE)",
			variantNET, recipe.CriteriaAcceleratorGB200, recipe.CriteriaServiceGKE, false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := gb200NetPreflightApplies(tt.variant, tt.accelerator, tt.service); got != tt.want {
				t.Errorf("gb200NetPreflightApplies() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFilterPreflightNodes(t *testing.T) {
	mkNode := func(name string, labels map[string]string) corev1.Node {
		return corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
		}
	}
	gb200a := mkNode("gb200-a", map[string]string{"node.kubernetes.io/instance-type": "p6e-gb200.36xlarge", "gpu-pool": "gb200"})
	gb200b := mkNode("gb200-b", map[string]string{"node.kubernetes.io/instance-type": "p6e-gb200.36xlarge", "gpu-pool": "gb200"})
	h100a := mkNode("h100-a", map[string]string{"node.kubernetes.io/instance-type": "p5.48xlarge", "gpu-pool": "h100"})
	unlabeled := mkNode("bare", nil)

	tests := []struct {
		name     string
		nodes    []corev1.Node
		override map[string]string
		service  recipe.CriteriaServiceType
		wantLen  int
		wantName string // first node name if wantLen==1, else ""
	}{
		{
			name:    "EKS mixed instance types — filter to first node's type",
			nodes:   []corev1.Node{gb200a, gb200b, h100a},
			service: recipe.CriteriaServiceEKS,
			wantLen: 2,
		},
		{
			name:    "EKS homogeneous — returns all",
			nodes:   []corev1.Node{gb200a, gb200b},
			service: recipe.CriteriaServiceEKS,
			wantLen: 2,
		},
		{
			name:     "user override narrows by arbitrary label",
			nodes:    []corev1.Node{gb200a, gb200b, h100a},
			override: map[string]string{"gpu-pool": "h100"},
			service:  recipe.CriteriaServiceEKS,
			wantLen:  1,
			wantName: "h100-a",
		},
		{
			name:    "non-EKS service and no override — probe all",
			nodes:   []corev1.Node{gb200a, h100a},
			service: recipe.CriteriaServiceOKE,
			wantLen: 2,
		},
		{
			name:    "EKS first node missing instance-type label — probe all",
			nodes:   []corev1.Node{unlabeled, gb200a},
			service: recipe.CriteriaServiceEKS,
			wantLen: 2,
		},
		{
			name:    "empty input",
			nodes:   nil,
			service: recipe.CriteriaServiceEKS,
			wantLen: 0,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := filterPreflightNodes(tt.nodes, tt.override, tt.service)
			if len(got) != tt.wantLen {
				t.Fatalf("filterPreflightNodes() len = %d, want %d (got %+v)", len(got), tt.wantLen, nodeNames(got))
			}
			if tt.wantName != "" && got[0].Name != tt.wantName {
				t.Errorf("filterPreflightNodes()[0].Name = %q, want %q", got[0].Name, tt.wantName)
			}
		})
	}
}

func nodeNames(nodes []corev1.Node) []string {
	out := make([]string, len(nodes))
	for i, n := range nodes {
		out[i] = n.Name
	}
	return out
}
