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
# UAT single-cluster reuse: recycle the AKS gpu-worker nodes (#1274 follow-on).
#
# Between cells on a shared session cluster the AICR stack is uninstalled and
# the GPU nodes must be returned to a clean-boot state, because the UAT's value
# is validating a from-scratch GPU-runtime deploy (driver install + skyhook
# tuning + the reboots they trigger must re-run on fresh nodes). A node the
# previous cell already tuned would let the readiness gate pass trivially — a
# FALSE pass.
#
# The AKS GPU pool is a FIXED-size VMSS with the cluster autoscaler OFF, so
# deleting instances would shrink it with nothing to replace them. Instead we
# `az vmss reimage` each GPU instance: the OS disk is reset to the node image
# and the instance reboots into AKS bootstrap, clearing all installed
# driver/kernel state while keeping the scarce quota-backed allocation. Freshness
# is proven by a CHANGED node bootID (a reimage forces a new boot) plus Ready —
# and this FAILS CLOSED if every GPU node has not cycled to a new boot within the
# budget. The runner's guard-fresh phase independently re-verifies the software
# side (no node advertises nvidia.com/gpu) before the next install.
#
# Uses the ambient az session (the workflow refreshes the federated login before
# this step) and the ambient kubeconfig (the workflow's Connect step) — it reads
# the node resource group + VMSS + instance ids from each node's providerID, so
# it needs no cluster/RG arguments for the reimage.
#
# Usage:
#   ./uat-azure-recycle-gpu.sh <cluster-name> <expected-gpu-count>
set -euo pipefail

CLUSTER="${1:-}"   # for logging/validation only; reimage targets come from providerID
EXPECTED="${2:-}"

if [[ -z "${CLUSTER}" || -z "${EXPECTED}" ]]; then
  echo "Usage: $0 <cluster-name> <expected-gpu-count>" >&2
  exit 2
fi
if ! [[ "${CLUSTER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "refusing to run: invalid cluster name '${CLUSTER}' (want ^[A-Za-z0-9][A-Za-z0-9-]*\$)" >&2
  exit 2
fi
if ! [[ "${EXPECTED}" =~ ^[1-9][0-9]*$ ]]; then
  echo "refusing to run: invalid expected-gpu-count '${EXPECTED}' (want a positive integer)" >&2
  exit 2
fi

# Reimage (OS-disk reset + reboot + AKS bootstrap rejoin) on an NDSH100v5 takes
# several minutes; budget generously but fail closed if exceeded.
RECYCLE_TIMEOUT_SECONDS="${RECYCLE_TIMEOUT_SECONDS:-900}" # 15 min
GPU_SELECTOR="${GPU_SELECTOR:-nodeGroup=gpu-worker}"

# Bind the kubeconfig to THIS cluster before enumerating anything. Without it the
# script would reimage whatever the ambient context happens to point at, and the
# validated ${CLUSTER} would constrain nothing — the AWS and GCP scripts both
# re-point their kubeconfig for exactly this reason. It also runs on the failure
# paths (the caller invokes it under always()), where a stale context is likeliest.
az aks get-credentials --name "${CLUSTER}" --resource-group "${CLUSTER}-rg" \
  --overwrite-existing --only-show-errors >/dev/null
if kubectl config current-context 2>/dev/null | grep -qv .; then
  echo "::error::no kubectl context after az aks get-credentials for ${CLUSTER}" >&2
  exit 1
fi

# The AKS-managed node resource group for this cluster. Every reimage target must
# live inside it; anything else means the kubeconfig is pointing at a different
# cluster and we must NOT reimage it.
NODE_RG="$(az aks show --name "${CLUSTER}" --resource-group "${CLUSTER}-rg" \
  --query nodeResourceGroup -o tsv --only-show-errors 2>/dev/null || true)"
if [[ -z "${NODE_RG}" ]]; then
  echo "::error::could not resolve the node resource group for ${CLUSTER}; refusing to reimage" >&2
  exit 1
fi
echo "Cluster ${CLUSTER} node resource group: ${NODE_RG}"

# Capture, per gpu-worker node: name, current bootID, and providerID. The bootID
# is the freshness anchor — a reimage boots the OS afresh, changing it.
before_json="$(kubectl get nodes -l "${GPU_SELECTOR}" -o json)"
mapfile -t gpu_nodes < <(echo "${before_json}" | jq -r '.items[].metadata.name')
if [[ "${#gpu_nodes[@]}" -eq 0 ]]; then
  echo "::error::no gpu-worker nodes found on ${CLUSTER}; nothing to recycle (session cluster unexpectedly empty)" >&2
  kubectl get nodes -o wide --show-labels >&2 || true
  exit 1
fi

# before_boot["<node>"]=<bootID>; group reimage targets by "<rg>|<vmss>".
declare -A before_boot=()
declare -A reimage_ids=()
while IFS=$'\t' read -r name boot pid; do
  before_boot["${name}"]="${boot}"
  local_rg="$(sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p' <<<"${pid}")"
  local_vmss="$(sed -n 's#.*/virtualMachineScaleSets/\([^/]*\)/.*#\1#p' <<<"${pid}")"
  local_id="$(sed -n 's#.*/virtualMachines/\([^/]*\).*#\1#p' <<<"${pid}")"
  if ! [[ "${local_rg}" =~ ^[A-Za-z0-9._()-]+$ && "${local_vmss}" =~ ^[A-Za-z0-9._-]+$ && "${local_id}" =~ ^[0-9]+$ ]]; then
    echo "::error::could not parse a valid VMSS reference from providerID '${pid}'; refusing to reimage" >&2
    exit 1
  fi
  # Fail closed unless the target belongs to THIS cluster's node resource group
  # (case-insensitive: ARM ids and the API can differ in case).
  if [[ "${local_rg,,}" != "${NODE_RG,,}" ]]; then
    echo "::error::node ${name} lives in resource group '${local_rg}', not ${CLUSTER}'s node resource group '${NODE_RG}'; refusing to reimage (wrong cluster in kubeconfig?)" >&2
    exit 1
  fi
  key="${local_rg}|${local_vmss}"
  reimage_ids["${key}"]="${reimage_ids[${key}]:-} ${local_id}"
done < <(echo "${before_json}" | jq -r '.items[] | [.metadata.name, (.status.nodeInfo.bootID // ""), (.spec.providerID // "")] | @tsv')

echo "Recycling ${#gpu_nodes[@]} gpu-worker node(s) via VMSS reimage: ${gpu_nodes[*]}"

echo "::group::Reimage gpu-worker VMSS instances"
for key in "${!reimage_ids[@]}"; do
  rg="${key%%|*}"
  vmss="${key##*|}"
  # Split the accumulated space-separated instance-id list robustly. Each id was
  # regex-validated as ^[0-9]+$ above, so read -a is exact (and keeps shellcheck
  # honest rather than suppressing the warning).
  read -r -a ids <<<"${reimage_ids[${key}]}"
  echo "reimaging VMSS ${vmss} (rg ${rg}) instances: ${ids[*]}"
  az vmss reimage --resource-group "${rg}" --name "${vmss}" --instance-ids "${ids[@]}" --output none
done
echo "::endgroup::"

echo "::group::Wait for reimaged gpu-worker nodes (timeout ${RECYCLE_TIMEOUT_SECONDS}s)"
deadline=$(( SECONDS + RECYCLE_TIMEOUT_SECONDS ))
fresh=0
while (( SECONDS < deadline )); do
  fresh=0
  # A node is "fresh" when it is Ready AND its bootID differs from before.
  while IFS=$'\t' read -r name boot ready; do
    [[ -z "${name}" ]] && continue
    if [[ "${ready}" == "True" && -n "${boot}" && "${boot}" != "${before_boot[${name}]:-}" ]]; then
      fresh=$(( fresh + 1 ))
    fi
  done < <(kubectl get nodes -l "${GPU_SELECTOR}" -o json 2>/dev/null \
    | jq -r '.items[] | [.metadata.name, (.status.nodeInfo.bootID // ""), ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "")] | @tsv')
  if (( fresh >= EXPECTED )); then
    echo "Recycle complete: ${fresh} gpu-worker node(s) reimaged (new bootID) and Ready (expected ${EXPECTED})"
    echo "::endgroup::"
    break
  fi
  echo "waiting for reimaged gpu-worker nodes (${fresh}/${EXPECTED} fresh-boot + Ready)..."
  sleep 20
done

if (( fresh < EXPECTED )); then
  echo "::endgroup::"
  echo "::error::gpu-node recycle timed out after ${RECYCLE_TIMEOUT_SECONDS}s: only ${fresh}/${EXPECTED} gpu-worker nodes reimaged and Ready" >&2
  kubectl get nodes -l "${GPU_SELECTOR}" -o wide >&2 || true
  echo "--- VMSS instance state ---" >&2
  for key in "${!reimage_ids[@]}"; do
    az vmss list-instances --resource-group "${key%%|*}" --name "${key##*|}" \
      --query '[].{id:instanceId,state:provisioningState}' -o table --only-show-errors >&2 2>/dev/null || true
  done
  exit 1
fi

# Reimage resets the OS disk but KEEPS the VM — so unlike the AWS/GCP paths
# (where a new instance yields a brand-new Node object) the Kubernetes Node
# object survives with everything the previous cell wrote on it: skyhook tuning
# labels/annotations, NFD/GFD feature labels, and the runtime-required taint once
# removed. A tuning operator that keys off those labels can then conclude
# "already tuned" on a node whose OS was just wiped — a FALSE PASS in exactly the
# scenario recycling exists to prevent. Delete the Node objects so the kubelet
# re-registers them clean (the AWS script prunes stale objects for the same
# reason); the kubelet re-registers within seconds since the VM is running.
echo "::group::Reset reimaged Node objects (clear prior-cell node state)"
for node in "${gpu_nodes[@]}"; do
  echo "deleting Node object ${node} so the kubelet re-registers it without prior-cell labels/taints"
  kubectl delete node "${node}" --ignore-not-found --timeout=60s || true
done

# Wait for them to come back Ready under fresh objects; fail closed if they do
# not, since an unregistered node is not a usable target for the next cell.
rereg_deadline=$(( SECONDS + 300 ))
while (( SECONDS < rereg_deadline )); do
  ready_count="$(kubectl get nodes -l "${GPU_SELECTOR}" -o json 2>/dev/null \
    | jq '[.items[] | select([.status.conditions[]? | select(.type == "Ready") | .status] | first == "True")] | length' 2>/dev/null || echo 0)"
  if (( ready_count >= EXPECTED )); then
    echo "re-registered: ${ready_count}/${EXPECTED} gpu-worker node(s) Ready with fresh Node objects"
    echo "::endgroup::"
    exit 0
  fi
  echo "waiting for re-registration (${ready_count}/${EXPECTED} Ready)..."
  sleep 15
done
echo "::endgroup::"
echo "::error::gpu-worker nodes did not re-register within 300s after the Node-object reset" >&2
kubectl get nodes -l "${GPU_SELECTOR}" -o wide >&2 || true
exit 1
