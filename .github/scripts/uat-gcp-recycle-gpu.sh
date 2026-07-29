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
# UAT single-cluster reuse: recycle the GKE gpu-worker nodes (#1274 follow-on).
#
# Between cells on a shared session cluster the AICR stack is uninstalled and
# the GPU nodes must be REPLACED with clean-boot instances, because the UAT's
# value is validating a from-scratch GPU-runtime deploy (driver install +
# skyhook tuning + the reboots they trigger must all re-run on fresh nodes). A
# node the previous cell already tuned would let the readiness gate pass
# trivially — a FALSE pass.
#
# This deletes the current gpu-worker GCE instances; the GKE node pool's managed
# instance group auto-heals by recreating them to restore the target size. It
# then waits for <expected> gpu-worker nodes to be Ready whose instance NAMES
# are DISJOINT from the deleted set (the MIG assigns fresh names), and FAILS
# CLOSED if that does not happen within the budget. The runner's guard-fresh
# phase independently re-verifies the software side before the next install.
#
# Usage:
#   GCP_REGION=us-central1 ./uat-gcp-recycle-gpu.sh <cluster-name> <expected-gpu-count>
set -euo pipefail

CLUSTER="${1:-}"
EXPECTED="${2:-}"

if [[ -z "${CLUSTER}" || -z "${EXPECTED}" ]]; then
  echo "Usage: $0 <cluster-name> <expected-gpu-count>" >&2
  exit 2
fi
: "${GCP_REGION:?Set GCP_REGION}"
# GKE cluster names are lowercase [a-z0-9-]; reject anything else.
if ! [[ "${CLUSTER}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "refusing to run: invalid cluster name '${CLUSTER}' (want ^[a-z][a-z0-9-]*\$)" >&2
  exit 2
fi
if ! [[ "${EXPECTED}" =~ ^[1-9][0-9]*$ ]]; then
  echo "refusing to run: invalid expected-gpu-count '${EXPECTED}' (want a positive integer)" >&2
  exit 2
fi

# MIG delete → recreate → node-pool bootstrap → Ready on an a3-megagpu-8g takes
# several minutes; budget generously but fail closed if exceeded.
RECYCLE_TIMEOUT_SECONDS="${RECYCLE_TIMEOUT_SECONDS:-900}" # 15 min
GPU_SELECTOR="${GPU_SELECTOR:-nodeGroup=gpu-worker}"

# Self-contained: refresh the kubeconfig (the actuator provisions a regional
# cluster, matching the pipeline's Connect step).
gcloud container clusters get-credentials "${CLUSTER}" --region "${GCP_REGION}" >/dev/null

# Snapshot each gpu-worker node as "<name>\t<project>/<zone>\t<bootID>".
# providerID is gce://<project>/<zone>/<instance-name>; the project is KEPT (not
# discarded) so the destructive delete below targets the tenancy the node
# actually lives in rather than the ambient gcloud default project.
gpu_node_snapshot() {
  kubectl get nodes -l "${GPU_SELECTOR}" -o json 2>/dev/null \
    | jq -r '.items[]
        | [ .metadata.name,
            ((.spec.providerID // "") | sub("^gce://"; "")),
            (.status.nodeInfo.bootID // ""),
            ([.status.conditions[]? | select(.type == "Ready") | .status] | first // "")
          ] | @tsv'
}

# Record pre-delete identity. Freshness is proven by a CHANGED bootID, not by a
# new instance NAME: a GKE node pool is MIG-managed, and when an instance is
# deleted out-of-band the MIG's auto-repair recreates it from the persisted
# managed-instance record — which is keyed by name — so the replacement can come
# back under the SAME name. Keying on the name would then never observe a
# "fresh" node and the wait would burn its whole budget on a recycle that
# actually succeeded. bootID changes on every boot regardless of naming, which
# is the same anchor the Azure script uses.
declare -A before_boot=()
projects=() zones=() names=()
while IFS=$'\t' read -r name path boot _ready; do
  [[ -z "${name}" ]] && continue
  proj="${path%%/*}"
  rest="${path#*/}"
  zone="${rest%%/*}"
  inst="${rest##*/}"
  if ! [[ "${proj}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && "${zone}" =~ ^[a-z][a-z0-9-]*$ && "${inst}" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "::error::unexpected GCE project/zone/name '${path}' parsed from providerID; refusing to delete" >&2
    exit 1
  fi
  before_boot["${name}"]="${boot}"
  projects+=("${proj}"); zones+=("${zone}"); names+=("${inst}")
done < <(gpu_node_snapshot)

if [[ "${#names[@]}" -eq 0 ]]; then
  echo "::error::no gpu-worker nodes found on ${CLUSTER}; nothing to recycle (session cluster unexpectedly empty)" >&2
  kubectl get nodes -o wide --show-labels >&2 || true
  exit 1
fi
echo "Recycling ${#names[@]} gpu-worker instance(s): ${names[*]}"

echo "::group::Delete gpu-worker instances (MIG will recreate)"
for i in "${!names[@]}"; do
  echo "deleting ${names[$i]} in ${projects[$i]}/${zones[$i]}..."
  # --async: fire the deletes and poll for replacements below rather than
  # blocking on each delete serially. --project pins the tenancy parsed from the
  # node's own providerID.
  gcloud compute instances delete "${names[$i]}" \
    --project "${projects[$i]}" --zone "${zones[$i]}" --quiet --async
done
echo "::endgroup::"

echo "::group::Wait for fresh gpu-worker replacements (timeout ${RECYCLE_TIMEOUT_SECONDS}s)"
deadline=$(( SECONDS + RECYCLE_TIMEOUT_SECONDS ))
fresh=0
while (( SECONDS < deadline )); do
  fresh=0
  # A node counts as fresh when it is Ready AND either its name is new (MIG
  # minted a new one) or its bootID changed (same name, genuinely rebooted from
  # a fresh instance).
  while IFS=$'\t' read -r name _path boot ready; do
    [[ -z "${name}" || "${ready}" != "True" || -z "${boot}" ]] && continue
    if [[ -z "${before_boot[${name}]+set}" || "${boot}" != "${before_boot[${name}]}" ]]; then
      fresh=$(( fresh + 1 ))
    fi
  done < <(gpu_node_snapshot)
  if (( fresh >= EXPECTED )); then
    echo "Recycle complete: ${fresh} fresh gpu-worker node(s) Ready (expected ${EXPECTED})"
    # Best-effort prune of node objects left behind by the deleted instances
    # (mirrors the AWS script): a lingering NotReady object would otherwise make
    # the next guard-fresh Ready-count check fail for its whole budget.
    for stale in $(kubectl get nodes -l "${GPU_SELECTOR}" -o json 2>/dev/null \
      | jq -r '.items[] | select([.status.conditions[]? | select(.type == "Ready") | .status] | first != "True") | .metadata.name'); do
      echo "pruning stale node object ${stale}"
      kubectl delete node "${stale}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    echo "::endgroup::"
    exit 0
  fi
  echo "waiting for fresh gpu-worker nodes (${fresh}/${EXPECTED} fresh-boot + Ready)..."
  sleep 20
done
echo "::endgroup::"

echo "::error::gpu-node recycle timed out after ${RECYCLE_TIMEOUT_SECONDS}s: only ${fresh}/${EXPECTED} fresh gpu-worker nodes Ready" >&2
kubectl get nodes -l "${GPU_SELECTOR}" -o wide >&2 || true
echo "--- MIG state (did the managed instance group recreate the deleted VMs?) ---" >&2
gcloud container clusters describe "${CLUSTER}" --region "${GCP_REGION}" \
  --format='value(nodePools[].name,nodePools[].status)' >&2 2>/dev/null || true
exit 1
