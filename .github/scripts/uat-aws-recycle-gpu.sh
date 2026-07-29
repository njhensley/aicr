#!/usr/bin/env bash
# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# UAT single-cluster reuse: recycle the EKS gpu-worker nodes (#1274 follow-on).
#
# Between cells on a shared session cluster the AICR stack is uninstalled and
# the GPU nodes must be REPLACED with clean-boot instances, because the value of
# the UAT is validating a from-scratch GPU-runtime deploy: skyhook node tuning,
# the driver/kernel-module install, and the reboots they trigger must all re-run
# on fresh nodes. A GPU node the previous cell already tuned would let the
# readiness gate pass trivially — a FALSE pass — so a shared cluster is only
# safe to reuse once its GPU nodes have been recycled.
#
# This terminates the current gpu-worker EC2 instances; the EKS managed node
# group's ASG launches fresh replacements to restore the desired count. It then
# waits for <expected> gpu-worker nodes to be Ready whose instance IDs are
# DISJOINT from the terminated set, and FAILS CLOSED if that does not happen
# within the budget — an unreplaced or leaked node must surface, never be read
# as "fresh". The runner's guard-fresh phase independently re-verifies the
# software side (no node advertises nvidia.com/gpu) before the next install.
#
# Usage:
#   AWS_REGION=us-east-1 ./uat-aws-recycle-gpu.sh <cluster-name> <expected-gpu-count>
set -euo pipefail

CLUSTER="${1:-}"
EXPECTED="${2:-}"

if [[ -z "${CLUSTER}" || -z "${EXPECTED}" ]]; then
  echo "Usage: $0 <cluster-name> <expected-gpu-count>" >&2
  exit 2
fi
: "${AWS_REGION:?Set AWS_REGION}"
# EKS cluster names are [A-Za-z0-9-]; reject anything else rather than pass an
# attacker-influenced value to aws eks update-kubeconfig.
if ! [[ "${CLUSTER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "refusing to run: invalid cluster name '${CLUSTER}' (want ^[A-Za-z0-9][A-Za-z0-9-]*\$)" >&2
  exit 2
fi
if ! [[ "${EXPECTED}" =~ ^[1-9][0-9]*$ ]]; then
  echo "refusing to run: invalid expected-gpu-count '${EXPECTED}' (want a positive integer)" >&2
  exit 2
fi

# ASG replacement (terminate → launch → kubelet join → Ready) on a p5.48xlarge
# takes several minutes; budget generously but fail closed if exceeded.
RECYCLE_TIMEOUT_SECONDS="${RECYCLE_TIMEOUT_SECONDS:-900}" # 15 min
GPU_SELECTOR="${GPU_SELECTOR:-nodeGroup=gpu-worker}"

# Self-contained: refresh the kubeconfig so this step does not depend on an
# earlier Connect step's context surviving a credential refresh.
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER}" >/dev/null

# ec2_id_from_provider extracts the EC2 instance id from an EKS node providerID
# (aws:///<az>/<instance-id>), printing nothing for a non-matching value.
gpu_ready_instance_ids() {
  # Ready gpu-worker nodes' instance ids, one per line.
  kubectl get nodes -l "${GPU_SELECTOR}" -o json 2>/dev/null \
    | jq -r '.items[]
        | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))
        | .spec.providerID // empty' \
    | sed -n 's#^aws:///[^/]*/##p'
}

# The full current gpu-worker instance set (Ready or not) is what we terminate.
mapfile -t before < <(kubectl get nodes -l "${GPU_SELECTOR}" -o json \
  | jq -r '.items[].spec.providerID // empty' | sed -n 's#^aws:///[^/]*/##p' | sort -u)
if [[ "${#before[@]}" -eq 0 ]]; then
  echo "::error::no gpu-worker nodes found on ${CLUSTER}; nothing to recycle (session cluster unexpectedly empty)" >&2
  kubectl get nodes -o wide --show-labels >&2 || true
  exit 1
fi
# Validate every extracted id before handing it to the AWS API.
for id in "${before[@]}"; do
  if ! [[ "${id}" =~ ^i-[0-9a-f]+$ ]]; then
    echo "::error::unexpected EC2 instance id '${id}' parsed from providerID; refusing to terminate" >&2
    exit 1
  fi
done
declare -A terminated=()
for id in "${before[@]}"; do terminated["${id}"]=1; done
echo "Recycling ${#before[@]} gpu-worker instance(s): ${before[*]}"

echo "::group::Terminate gpu-worker instances"
aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${before[@]}" \
  --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
echo "::endgroup::"

echo "::group::Wait for fresh gpu-worker replacements (timeout ${RECYCLE_TIMEOUT_SECONDS}s)"
deadline=$(( SECONDS + RECYCLE_TIMEOUT_SECONDS ))
fresh=0
while (( SECONDS < deadline )); do
  fresh=0
  while IFS= read -r id; do
    [[ -n "${id}" && -z "${terminated[${id}]:-}" ]] && fresh=$(( fresh + 1 ))
  done < <(gpu_ready_instance_ids)
  if (( fresh >= EXPECTED )); then
    echo "Recycle complete: ${fresh} fresh gpu-worker node(s) Ready (expected ${EXPECTED})"
    echo "::endgroup::"
    # Best-effort prune of any lingering terminated node objects (the cloud
    # controller usually removes them; do not fail if it already has).
    for id in "${before[@]}"; do
      node="$(kubectl get nodes -o json 2>/dev/null \
        | jq -r --arg id "${id}" '.items[] | select((.spec.providerID // "") | endswith("/" + $id)) | .metadata.name' | head -n1)"
      [[ -n "${node}" ]] && kubectl delete node "${node}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    exit 0
  fi
  echo "waiting for fresh gpu-worker nodes (${fresh}/${EXPECTED} fresh + Ready)..."
  sleep 20
done
echo "::endgroup::"

echo "::error::gpu-node recycle timed out after ${RECYCLE_TIMEOUT_SECONDS}s: only ${fresh}/${EXPECTED} fresh gpu-worker nodes Ready" >&2
kubectl get nodes -l "${GPU_SELECTOR}" -o wide >&2 || true
# Distinguish "the ASG has not relaunched yet" from "the relaunch is failing".
# The GPU pool draws on a capacity reservation (capacity-reservations-only), so
# replacements cannot launch until the terminating instances release their slots
# — that lag and a genuine InsufficientInstanceCapacity look identical from the
# node list alone. Scaling activities name which one it is.
echo "--- recent ASG scaling activities (why did replacements not launch?) ---" >&2
for asg in $(aws autoscaling describe-auto-scaling-groups --region "${AWS_REGION}" \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${CLUSTER}')].AutoScalingGroupName" \
  --output text 2>/dev/null || true); do
  echo "ASG ${asg}:" >&2
  aws autoscaling describe-scaling-activities --region "${AWS_REGION}" \
    --auto-scaling-group-name "${asg}" --max-items 5 \
    --query 'Activities[].[StatusCode,StatusMessage,Cause]' --output text >&2 2>/dev/null || true
done
exit 1
