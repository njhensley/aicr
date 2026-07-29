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
# shellcheck shell=bash
#
# Shared UAT phase library. Holds the cloud-agnostic phase implementations
# (prep, install, conformance, train, serve, verify, debug) and the phase
# dispatcher, sourced by the thin per-cloud runners tests/uat/{aws,gcp,azure}/run.
# The runners were ~identical (aws/gcp differed only in comment wording; azure
# added a federated-session refresh); this consolidates the shared body here and
# leaves each runner as a shim that sources this file and calls uat_main "$@".
#
# Cloud-specific behavior is injected through the cloud_refresh_credentials hook
# (default no-op; Azure overrides it to redeem a fresh federated OIDC assertion)
# and CLOUD_REFRESH_INTERVAL_SECONDS. Everything else is identical across clouds.
#
# Usage (from a per-cloud runner):
#   AICR_BIN=./aicr RUN_ID=12345 ./run <phase> <test-config.yaml>
#
# Phases:
#   prep         snapshot + recipe + dry-run validate + bundle
#   install      helmfile apply (deploys gpu-operator, kubeflow/dynamo, ...)
#   conformance  validate ALL phases (deployment + conformance + performance)
#                + emit signed evidence bundle
#   train        submit TrainJob, wait for completion, capture logs
#                (intent=training CUJ)
#   serve        deploy a DynamoGraphDeployment, wait for readiness, hit the
#                OpenAI-compatible endpoint, assert a completion, capture logs
#                (intent=inference CUJ — the DC3 counterpart of `train`)
#   verify       aicr evidence verify against the signed bundle
#   debug        snapshot live cluster state into cluster-debug/ (nodes, taints,
#                events, operator CRs incl. Skyhook status, operator/check-Job
#                logs) — best-effort, run on failure BEFORE teardown
#   compat       (session reuse) resolve the recipe and check its
#                K8s.server.version constraint against the live cluster; exit 3
#                = incompatible (caller fails the cell; see docs)
#   guard-fresh  (session reuse) fail closed unless the shared cluster is a
#                valid from-scratch target (gpu-worker nodes Ready, no node
#                advertises nvidia.com/gpu)
#   uninstall    (session reuse) helmfile destroy + sweep so the next cell on a
#                shared session cluster installs from a clean slate
#   recycle      (session reuse) replace the GPU nodes with clean-boot instances
#                via the per-cloud cloud_recycle_gpu_nodes hook (fails closed)
#   session-cell (session reuse) the whole between-provision cell in order:
#                compat -> guard-fresh -> prep -> install -> conformance -> CUJ
#                -> verify -> uninstall -> recycle (for local reproduction)
#   all          run every phase in order (for local reproduction); the CUJ
#                phase is chosen by the config's recipe intent — `train` for
#                training, `serve` for inference
#
# Required env:
#   AICR_BIN    Path to the aicr binary
#   RUN_ID      Per-run correlation tag (`run-<id>`) applied to the evidence
#               push target (e.g. ${{ github.run_id }} in CI, or `local-$(date +%s)`)
#
# Working files are written to $PWD: snapshot.yaml, recipe.yaml, bundle/,
# dry-run.json, report.json, evidence/, evidence-result.json, train-logs/.

# Shared, cloud-agnostic cluster debug-bundle collector (collect_cluster_debug,
# capture_skyhook_snapshot), invoked by the `debug` phase on failure and inline
# from phase_conformance. Lives alongside this file in tests/uat/lib/.
# shellcheck source=./collect-debug.sh
source "$(dirname "${BASH_SOURCE[0]}")/collect-debug.sh"

# Train-job knobs (overridable for local reproduction or future inference variant).
TRAINJOB_NAMESPACE="${TRAINJOB_NAMESPACE:-kubeflow}"
TRAINJOB_NAME="${TRAINJOB_NAME:-pytorch-mnist}"
TRAINJOB_IMAGE="${TRAINJOB_IMAGE:-kubeflow/pytorch-dist-mnist:v1-9e12c68}"
TRAINJOB_TIMEOUT_SECONDS="${TRAINJOB_TIMEOUT_SECONDS:-1200}" # 20 min
# TrainJob node count. Defaults to 2 to span the cloud lanes' 2-GPU pools (and
# exercise multi-node distributed training); the single-GPU nvkind lane
# (tests/uat/kind/run) overrides to 1.
TRAINJOB_NUM_NODES="${TRAINJOB_NUM_NODES:-2}"
HELMFILE_TIMEOUT_SECONDS="${HELMFILE_TIMEOUT_SECONDS:-1200}" # 20 min
# Budget for the post-install readiness gate (see phase_install), which runs
# `aicr validate --phase deployment` until it passes READINESS_CONSECUTIVE_PASSES
# times in a row. This is the gate window ONLY -- it is entered AFTER helmfile
# apply returns, so the workflow install step must budget helmfile + this. It
# must span nodewright (skyhook) node tuning -- which REBOOTS the GPU node and
# re-inits the gpu-operator operands after the operator first reports ready (each
# validate run now polls internally, up to GPUReadinessTimeout, to ride through a
# reboot) -- plus cold-boot GPU-operator convergence
# (driver/toolkit/device-plugin/DCGM) and prometheus-adapter APIService
# aggregation, across the required consecutive passes. Sized at 60m because
# nodewright (skyhook) tuning plus its reboot cycles alone can run past 30m on a
# cold GPU node (the earlier 30m budget timed out purely waiting on tuning), and
# the gate must still have room to observe the required consecutive passes after
# tuning settles. Fails closed if exceeded.
READINESS_TIMEOUT_SECONDS="${READINESS_TIMEOUT_SECONDS:-3600}" # 60 min
# The gate requires the deployment phase to pass this many times CONSECUTIVELY
# before declaring readiness. A single pass proves "converged at instant T", not
# "will stay converged": nodewright (skyhook) tuning reboots the GPU node more
# than once (the tuning packages carry interrupt: reboot) and re-opens
# status=in_progress after each reboot and for each newly-joined GPU node, so a
# pass can land in a lull between reboot cycles. Requiring N consecutive passes,
# spaced by the retry sleep, ensures the reboots have settled before the
# conformance phase (`--phase all`) runs -- any regression resets the counter.
READINESS_CONSECUTIVE_PASSES="${READINESS_CONSECUTIVE_PASSES:-2}"

# Inference-serve knobs (phase_serve; overridable for local reproduction). The
# defaults mirror the served DynamoGraphDeployment in demos/cuj2-inference.md
# (demos/workloads/inference/vllm-agg.yaml) so CI and the demo stay in lockstep.
SERVE_NAMESPACE="${SERVE_NAMESPACE:-dynamo-workload}"
SERVE_NAME="${SERVE_NAME:-vllm-agg}"
SERVE_QUEUE="${SERVE_QUEUE:-dynamo}"
SERVE_MODEL="${SERVE_MODEL:-Qwen/Qwen3-0.6B}"
SERVE_RUNTIME_IMAGE="${SERVE_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1}"
# GPU worker placement. The demo pins nodeGroup=gpu-worker; both UAT clusters
# label their GPU pool the same way (tests/uat/*/cluster-config.yaml), so the
# default lands the decode worker on the GPU node on either cloud.
SERVE_GPU_NODE_SELECTOR_KEY="${SERVE_GPU_NODE_SELECTOR_KEY:-nodeGroup}"
SERVE_GPU_NODE_SELECTOR_VALUE="${SERVE_GPU_NODE_SELECTOR_VALUE:-gpu-worker}"
SERVE_FRONTEND_PORT="${SERVE_FRONTEND_PORT:-8000}"
# Readiness budget: image pull of the multi-GB vllm-runtime + model download +
# engine warmup on a cold GPU node. Generous; fails closed if exceeded.
SERVE_READY_TIMEOUT_SECONDS="${SERVE_READY_TIMEOUT_SECONDS:-1800}" # 30 min
SERVE_REQUEST_TIMEOUT_SECONDS="${SERVE_REQUEST_TIMEOUT_SECONDS:-120}" # 2 min

# Single-cluster reuse (session mode) knobs. A reuse-enabled nightly batch runs
# many (version x intent) cells against ONE cluster; between cells
# phase_uninstall tears the AICR stack down (bounded by these) so the next cell
# installs from a clean slate, and phase_guard_fresh / phase_compat gate the
# reuse. The GPU-node recycle itself is cloud-specific and lives in
# .github/scripts/uat-<cloud>-recycle-gpu.sh, not here.
UNINSTALL_TIMEOUT_SECONDS="${UNINSTALL_TIMEOUT_SECONDS:-600}"          # 10 min (helmfile destroy)
NAMESPACE_DELETE_TIMEOUT_SECONDS="${NAMESPACE_DELETE_TIMEOUT_SECONDS:-300}" # 5 min (finalizer drain)
# Budget for phase_guard_fresh to poll the shared cluster into a clean
# from-scratch state — a freshly provisioned (session-up) or freshly recycled
# (between-cell) GPU pool may still be joining, and a just-terminated old node
# object can linger NotReady for a moment. Fails closed if it never converges.
GUARD_TIMEOUT_SECONDS="${GUARD_TIMEOUT_SECONDS:-300}" # 5 min
# The clean state must hold this many consecutive observations before
# phase_guard_fresh certifies it. One observation cannot distinguish "clean" from
# "a surviving DaemonSet has not been rescheduled onto the new nodes yet" — the
# same reason phase_install requires READINESS_CONSECUTIVE_PASSES.
GUARD_CONSECUTIVE_PASSES="${GUARD_CONSECUTIVE_PASSES:-2}"
# Opt-in: also require that NO node advertises allocatable nvidia.com/gpu. Only
# valid where AICR owns the device plugin. GKE (gpuDriverInstallation: DEFAULT)
# and AKS (gpuDriverInstall: true) have the PLATFORM install the driver and its
# own device-plugin DaemonSet, so a freshly recycled node advertises the resource
# with zero AICR components installed and the gate would never converge there.
# The AWS runner opts in (see tests/uat/aws/run); the default is off.
GUARD_REQUIRE_NO_GPU_ADVERTISED="${GUARD_REQUIRE_NO_GPU_ADVERTISED:-false}"
# Exit code phase_compat uses to signal "this reservation's cluster shape cannot
# satisfy this cell's recipe" — distinct from a generic error (1) for clarity in
# local reproduction. The pipeline treats any non-zero compat exit as a hard CELL
# FAILURE: there is no reprovision path (the reservation has a single
# cluster-config, so a dedicated cluster would be the same shape and equally
# incompatible), so the cost of failing closed here is a failed cell, which is
# the same outcome a per-cell run would reach on a genuine incompatibility.
COMPAT_EXIT_INCOMPATIBLE=3

# cloud_refresh_credentials: hook to refresh cloud credentials mid-run. Default
# no-op — AWS/GCP sessions either outlast the job or are refreshed by the
# workflow (configure-aws-credentials / google-github-actions/auth). Azure's
# federated CI session self-expires (~5-minute OIDC assertion), so its runner
# overrides this to redeem a fresh assertion. Called periodically inside the
# readiness gate (gated by CLOUD_REFRESH_INTERVAL_SECONDS) and once before debug
# collection. Must return non-zero on failure so the gate's timer only advances
# on a successful refresh.
cloud_refresh_credentials() { :; }

# cloud_recycle_gpu_nodes: hook that replaces the GPU nodes with clean-boot ones
# between cells on a shared session cluster. Cloud-specific by nature (EKS ASG
# terminate / GKE MIG recreate / AKS VMSS reimage), so each per-cloud runner
# overrides it (tests/uat/<cloud>/run) — mirroring cloud_refresh_credentials.
# The default FAILS CLOSED: a cloud without an implementation must not silently
# skip the recycle and let the next cell validate a pre-tuned GPU pool.
cloud_recycle_gpu_nodes() {
  echo "::error::no GPU-node recycle implementation for this cloud; refusing to continue (the next cell would install onto already-tuned nodes and could record a false pass)" >&2
  return 1
}

# How often the readiness gate calls cloud_refresh_credentials. Effectively-never
# by default (AWS/GCP need no mid-gate refresh); Azure's runner lowers it.
CLOUD_REFRESH_INTERVAL_SECONDS="${CLOUD_REFRESH_INTERVAL_SECONDS:-999999999}"

inject_push_target() {
  local current repo expected
  current="$(yq '.spec.validate.evidence.attestation.push' "${config}")"
  repo="${current%%:run-*}"
  expected="${repo}:run-${RUN_ID}"
  if [[ "${current}" != "${expected}" ]]; then
    yq -i ".spec.validate.evidence.attestation.push = \"${expected}\"" "${config}"
  fi
  echo "evidence push target: $(yq '.spec.validate.evidence.attestation.push' "${config}")"
}

phase_prep() {
  # Capture cluster state on snapshot failure so the post-mortem has
  # actual pod scheduling / image pull / event data instead of just the
  # generic "pod did not become ready" timeout the aicr CLI prints.
  local snapshot_ns
  snapshot_ns="$(yq '.spec.snapshot.agent.namespace // "aicr-validation"' "${config}")"
  echo "::group::Snapshot live cluster"
  if ! "${AICR_BIN}" snapshot --config "${config}"; then
    echo "::endgroup::"
    echo "::group::Snapshot failure debug"
    echo "--- nodes ---"
    kubectl get nodes -o wide --show-labels 2>&1 || true
    echo "--- node taints ---"
    kubectl get nodes -o json 2>/dev/null | \
      jq -r '.items[] | "\(.metadata.name)\n  taints: \(.spec.taints // [])\n  conditions: \([.status.conditions[] | select(.type == "Ready") | .status])"' || true
    echo "--- pods in ${snapshot_ns} ---"
    kubectl get pods -n "${snapshot_ns}" -o wide 2>&1 || true
    for p in $(kubectl get pods -n "${snapshot_ns}" -o name 2>/dev/null); do
      echo "--- describe ${p} ---"
      kubectl describe -n "${snapshot_ns}" "${p}" 2>&1 || true
      echo "--- logs ${p} (all containers, last 50 lines) ---"
      kubectl logs -n "${snapshot_ns}" "${p#pod/}" --all-containers --tail=50 2>&1 || true
    done
    echo "::endgroup::"
    exit 1
  fi
  test -f snapshot.yaml
  echo "::endgroup::"

  echo "::group::Generate recipe"
  "${AICR_BIN}" recipe --config "${config}"
  test -f recipe.yaml
  echo "::endgroup::"

  echo "::group::Validate (dry-run, --no-cluster)"
  # Validate against a copy of the config with spec.validate.evidence stripped so
  # the offline dry-run cannot emit/sign/push an evidence bundle. --no-cluster
  # reports every check as "skipped", so an attestation would attest to nothing;
  # worse, with evidence.attestation.{out,push} set (as UAT configs are) the
  # dry-run would sign and push a bundle to the same OCI repo the conformance
  # phase's authoritative validate later pushes to, leaving two independently-
  # signed bundles and breaking `evidence verify` (signed subject != pulled
  # run-tagged digest). Mirrors the readiness-gate strip in phase_conformance.
  # Belt-and-suspenders with the CLI's own --no-cluster guard: this keeps prep
  # safe even against an older released aicr that lacks that guard.
  # Run in a subshell with an EXIT trap so the temp config is removed on every
  # exit path (normal return, set -e abort on validate failure, interrupt),
  # mirroring the signing subshell below. A non-zero validate rc propagates out
  # of the subshell and aborts prep under set -e, as before.
  (
    prep_config="$(mktemp)"
    trap 'rm -f "${prep_config}"' EXIT
    yq 'del(.spec.validate.evidence)' "${config}" > "${prep_config}"
    "${AICR_BIN}" validate \
      --config "${prep_config}" \
      --phase deployment \
      --no-cluster \
      --output dry-run.json
  )
  test -f dry-run.json
  echo "::endgroup::"

  echo "::group::Generate bundle"
  "${AICR_BIN}" bundle --config "${config}"
  test -f bundle/helmfile.yaml || {
    echo "expected bundle/helmfile.yaml (deployer: helmfile) — got:" >&2
    ls -la bundle >&2 || true
    exit 1
  }
  echo "::endgroup::"
}

phase_install() {
  command -v helmfile >/dev/null || { echo "helmfile not on PATH" >&2; exit 1; }
  command -v helm     >/dev/null || { echo "helm not on PATH"     >&2; exit 1; }

  # Read helm-diff version from the single source of truth (.settings.yaml).
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local REPO_ROOT="${SCRIPT_DIR}/../../.."
  local HELM_DIFF_VERSION
  HELM_DIFF_VERSION="$(yq -r '.testing_tools.helm_diff' "${REPO_ROOT}/.settings.yaml")"

  echo "::group::Install helm-diff plugin (${HELM_DIFF_VERSION})"
  # Check installed version; reinstall if missing or at a different version so the
  # .settings.yaml pin is always effective (not just "any version is fine").
  local installed_ver
  installed_ver="$(helm plugin list 2>/dev/null | awk '$1=="diff" {print $2}')"
  if [[ "${installed_ver}" == "${HELM_DIFF_VERSION#v}" ]]; then
    echo "helm-diff ${HELM_DIFF_VERSION} already installed"
  else
    if [[ -n "${installed_ver}" ]]; then
      echo "helm-diff ${installed_ver} installed; removing to pin ${HELM_DIFF_VERSION}"
      helm plugin remove diff
    fi
    # Install from the signed release tarball (helm-diff's recommended Helm 4
    # method). Helm 4 verifies plugin provenance by default (--verify=true):
    # the .prov signature is checked against a keyring. Import the maintainer's
    # release key, pin it to the published fingerprint (fail closed on
    # mismatch), export it to a legacy keyring, and verify against it.
    #
    # Run in a subshell with an EXIT trap so the temp GNUPGHOME/keyring are
    # removed on every path — including a set -e (L41) abort, where a RETURN
    # trap would not fire. The subshell keeps the trap and temp vars scoped to
    # this block without disturbing the parent shell's traps.
    (
      HELM_DIFF_KEY_FPR="C5645EF47482257A1F806D2BEA17A2A206AFF8CD"
      GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
      HELM_DIFF_KEYRING="$(mktemp)"
      trap 'rm -rf "${GNUPGHOME}" "${HELM_DIFF_KEYRING}"' EXIT
      curl -fsSL "https://github.com/databus23.gpg" | gpg --import
      if ! gpg --with-colons --fingerprint \
          | awk -F: '/^fpr:/{print $10}' | grep -qx "${HELM_DIFF_KEY_FPR}"; then
        echo "::error::helm-diff release key fingerprint mismatch (expected ${HELM_DIFF_KEY_FPR})" >&2
        exit 1
      fi
      gpg --export "${HELM_DIFF_KEY_FPR}" > "${HELM_DIFF_KEYRING}"
      helm plugin install "https://github.com/databus23/helm-diff/releases/download/${HELM_DIFF_VERSION}/helm-diff-linux-amd64.tgz" \
        --keyring "${HELM_DIFF_KEYRING}"
    )
  fi
  echo "::endgroup::"

  # Retry helmfile apply on transient cluster-API errors (control-plane
  # warmup, throttling, etc.). helmfile is idempotent — re-running on a
  # partial-install state converges on the desired set. The 3 attempts SHARE a
  # single HELMFILE_TIMEOUT_SECONDS wall-clock budget (each attempt is capped at
  # the remaining budget, like the readiness gate below), not a full budget each:
  # transient errors fail fast so sharing leaves ample time for retries, while a
  # genuine hang cannot stretch install to 3x the budget. This bounds worst-case
  # install (helmfile + gate) within the workflow step's timeout-minutes.
  local helmfile_deadline=$(( SECONDS + HELMFILE_TIMEOUT_SECONDS ))
  local success=false helm_remaining
  for attempt in 1 2 3; do
    if (( SECONDS >= helmfile_deadline )); then
      # Distinguish a budget-starved run (a slow-but-progressing apply consumed
      # the shared window) from a genuine 3-strike failure: log why attempts
      # 2-3 never launched.
      echo "helmfile shared ${HELMFILE_TIMEOUT_SECONDS}s budget exhausted after attempt $(( attempt - 1 )); not starting attempt ${attempt}"
      break
    fi
    helm_remaining=$(( helmfile_deadline - SECONDS ))
    (( helm_remaining < 1 )) && helm_remaining=1
    echo "::group::helmfile apply attempt ${attempt}/3 (timeout ${helm_remaining}s of ${HELMFILE_TIMEOUT_SECONDS}s shared budget)"
    if ( cd bundle && timeout "${helm_remaining}" helmfile apply --skip-diff-on-install ); then
      success=true
      echo "::endgroup::"
      break
    fi
    echo "helmfile apply attempt ${attempt} failed"
    echo "::endgroup::"
    if (( attempt < 3 )); then
      echo "waiting 30s before retry"
      sleep 30
    fi
  done
  if [[ "${success}" != "true" ]]; then
    echo "::error::helmfile apply failed after 3 attempts" >&2
    exit 1
  fi

  echo "::group::Cluster state post-install"
  kubectl get nodes -o wide
  kubectl get pods -A | grep -Ev '\s+Running\s+|\s+Completed\s+' || true
  echo "::endgroup::"

  # Readiness gate: run the deployment validation phase -- the authoritative
  # expected-resources / ClusterPolicy / DRA / nodewright checks the later
  # `--phase all` run gates on -- in a retry loop until it passes
  # READINESS_CONSECUTIVE_PASSES times in a row. `helmfile apply` returns before
  # operator-driven convergence, and nodewright (skyhook) reboots the GPU node
  # AFTER gpu-operator first reports ready, re-initing the operands; proxy
  # signals (ClusterPolicy=ready, Skyhook status.status) read that transient
  # state as "done" prematurely, so we gate on the real check. A SINGLE pass only
  # proves "converged at instant T" -- skyhook tuning reboots the node more than
  # once and re-opens status=in_progress between cycles, so a lone pass can land
  # in a lull. Requiring consecutive passes (each spaced by the retry sleep, and
  # each riding through a transient in_progress via expected-resources' own poll)
  # ensures the reboots have settled before conformance runs. Any failure resets
  # the streak. Fail-closed: the install fails if the streak is never reached
  # within the budget.
  #
  # Run against a copy of the config with spec.validate.evidence stripped so the
  # gate never emits/pushes an evidence bundle -- that is the conformance phase's
  # job (phase_conformance, `--phase all`).
  local gate_config gate_log
  gate_config="$(mktemp)"
  gate_log="$(mktemp)"
  yq 'del(.spec.validate.evidence)' "${config}" > "${gate_config}"
  # Persist each attempt's validate output (timestamped) to the bundle so the
  # status.status progression across the tuning-settling window survives into the
  # failure artifact — capturing the complete→in_progress flips as they happen
  # (see CLUSTER_DEBUG_GATE_LOG in tests/uat/lib/collect-debug.sh). The mktemp
  # gate_log is still used for the immediate on-screen failure diagnostic.
  mkdir -p "${CLUSTER_DEBUG_DIR}"
  : > "${CLUSTER_DEBUG_GATE_LOG}" || true
  local ready_deadline=$(( SECONDS + READINESS_TIMEOUT_SECONDS ))
  local attempt=1 streak=0 ready=false remaining attempt_result
  # Baseline for the periodic cloud-credential refresh (see cloud_refresh_credentials).
  local last_cred_refresh=${SECONDS}
  echo "::group::Readiness gate: validate --phase deployment x${READINESS_CONSECUTIVE_PASSES} consecutive (timeout ${READINESS_TIMEOUT_SECONDS}s)"
  # Check the deadline BEFORE each attempt so no validation run is launched once
  # the budget is spent (a single run can itself take minutes). The last
  # attempt's output is captured in gate_log for the failure diagnostic rather
  # than re-running validate past the deadline.
  while (( SECONDS < ready_deadline )); do
    # Keep cloud credentials fresh across the gate window. Default no-op; Azure's
    # federated CI session self-expires (~5m assertion) and overrides
    # cloud_refresh_credentials + lowers CLOUD_REFRESH_INTERVAL_SECONDS. The timer
    # only advances on success, so a transient refresh failure retries on the next
    # attempt while the currently-cached tokens are still valid.
    if (( SECONDS - last_cred_refresh >= CLOUD_REFRESH_INTERVAL_SECONDS )); then
      if cloud_refresh_credentials; then
        last_cred_refresh=${SECONDS}
      else
        echo "::warning::cloud credential refresh failed; retrying on the next gate attempt"
      fi
    fi
    # Bound each attempt with `timeout` (like the helmfile retry above) so a hung
    # validate cannot block past the deadline -- the loop only re-checks
    # ready_deadline between attempts. Cap at the remaining budget so no single
    # attempt overruns the gate window. Clamp to >= 1: SECONDS is re-read here and
    # can tick to ready_deadline between the while guard and this line, and
    # `timeout 0` means "no timeout" (runs forever) -- the exact hang we guard.
    remaining=$(( ready_deadline - SECONDS ))
    (( remaining < 1 )) && remaining=1
    if timeout "${remaining}" "${AICR_BIN}" validate --config "${gate_config}" --phase deployment --output /dev/null > "${gate_log}" 2>&1; then
      attempt_result=pass
      streak=$(( streak + 1 ))
      echo "deployment phase passed (attempt ${attempt}, streak ${streak}/${READINESS_CONSECUTIVE_PASSES})"
      if (( streak >= READINESS_CONSECUTIVE_PASSES )); then
        ready=true
      fi
    else
      # A regression (e.g. nodewright flipped back to in_progress on a reboot)
      # invalidates the streak -- start over.
      attempt_result=fail
      if (( streak > 0 )); then
        echo "deployment phase regressed after ${streak} consecutive pass(es); resetting streak"
      fi
      streak=0
      echo "deployment phase not ready (attempt ${attempt})"
    fi
    # Append this attempt (timestamped) to the persistent gate series. This is the
    # status.status time-series that lets a reviewer see the tuning flips directly.
    {
      echo "===== attempt ${attempt} @ $(date -u +%Y-%m-%dT%H:%M:%SZ) result=${attempt_result} streak=${streak}/${READINESS_CONSECUTIVE_PASSES} ====="
      cat "${gate_log}"
      echo
    } >> "${CLUSTER_DEBUG_GATE_LOG}" 2>/dev/null || true
    [[ "${ready}" == true ]] && break
    attempt=$(( attempt + 1 ))
    sleep 15
  done
  if [[ "${ready}" != true ]]; then
    echo "::error::deployment readiness gate did not reach ${READINESS_CONSECUTIVE_PASSES} consecutive passes within ${READINESS_TIMEOUT_SECONDS}s (last streak ${streak}); last attempt output:" >&2
    cat "${gate_log}" >&2 || true
    rm -f "${gate_config}" "${gate_log}"
    echo "::endgroup::"
    exit 1
  fi
  rm -f "${gate_config}" "${gate_log}"
  echo "deployment readiness gate passed (${READINESS_CONSECUTIVE_PASSES} consecutive, ${attempt} attempt(s))"
  echo "::endgroup::"
}

phase_conformance() {
  inject_push_target
  # Run ALL validation phases, not just conformance. The deployment phase is
  # the readiness barrier this UAT was missing: its health-check asserts poll
  # (chainsaw assert, ~6m budget) until the GPU stack converges — gpu-operator
  # ClusterPolicy reaches state=ready, the DRA kubelet-plugin DaemonSet is
  # fully rolled out, and nodewright node tuning completes. The helmfile bundle
  # (unlike the helm deploy.sh, which `kubectl wait`s on these) returns from
  # `helmfile apply` as soon as each release's own resources are ready, leaving
  # operator-driven work in flight; running conformance alone then validated a
  # not-yet-converged cluster and failed. The deployment phase gates that
  # convergence deployer-agnostically. The performance phase's only check,
  # nccl-all-reduce-bw, needs >=2 GPU nodes for its East-West fabric test and
  # is now active: each cloud's cluster-config provisions 2 GPU nodes in the
  # gpu-worker pool. If the pool is ever scaled back to a single GPU node, the
  # check skips gracefully (skip != fail) rather than failing.
  # Evidence is rendered/attested from the merged multi-phase report, so the
  # signed bundle covers all phases.

  # First-party platform sanity check. The emitted bundle's TestGrid tab
  # coordinate is derived from the recipe's author-declared `platform`
  # (inference→dynamo, training→kubeflow) and is NOT captured by the
  # fingerprint — pkg/fingerprint/match.go treats the platform dimension as
  # uncaptured — so a mis-declared platform would silently route evidence to
  # the wrong tab. Cross-check that the platform operator's workload CRD is
  # actually installed on the cluster the bundle deployed, so the declared
  # coordinate matches the deployed component set. Unknown/other platforms are
  # skipped (no false failure), a known platform whose CRD is absent fails closed.
  # Runs BEFORE `validate --phase all` emits + pushes the signed bundle: a
  # mis-declared platform must fail the leg before any incorrectly-routed
  # evidence is published to the wrong TestGrid tab, not after.
  echo "::group::Platform coordinate sanity check"
  local platform crd
  platform="$(yq -r '.criteria.platform // ""' recipe.yaml)"
  case "${platform}" in
    dynamo)   crd="dynamographdeployments.nvidia.com" ;;
    kubeflow) crd="trainjobs.trainer.kubeflow.org" ;;
    *)        crd="" ;;  # unknown/other platform: no cross-check wired
  esac
  if [[ -z "${crd}" ]]; then
    echo "recipe declares platform '${platform}': no workload-CRD cross-check wired for it (skipping)"
  elif ! kubectl get crd "${crd}" >/dev/null 2>&1; then
    echo "::error::recipe declares platform=${platform} but its workload CRD ${crd} is not installed — the emitted evidence would map to the wrong TestGrid tab" >&2
    kubectl get crd 2>&1 | head -50 >&2 || true
    echo "::endgroup::"
    exit 1
  else
    echo "platform=${platform}: workload CRD ${crd} present"
  fi
  echo "::endgroup::"

  echo "::group::Validate (all phases) + emit signed evidence"
  # Capture the exit code rather than letting `set -e` abort: on a validate
  # failure we snapshot the skyhook CR + node reboot fingerprint INLINE — seconds
  # after the failing check gave up, while status.status is most likely still
  # in_progress — before propagating the failure. The teardown-time collector runs
  # minutes later, by when the CR may have re-converged and hidden the flip.
  local vrc=0
  "${AICR_BIN}" validate \
    --config "${config}" \
    --phase all \
    --output report.json || vrc=$?
  echo "::endgroup::"
  if (( vrc != 0 )); then
    capture_skyhook_snapshot conformance-validate
    return "${vrc}"
  fi

  if [[ ! -f ./evidence/pointer.yaml ]]; then
    echo "evidence pointer not emitted at ./evidence/pointer.yaml" >&2
    ls -la ./evidence >&2 || true
    exit 1
  fi
  echo "evidence pointer:"
  cat ./evidence/pointer.yaml
}

phase_train() {
  echo "::group::Submit TrainJob"
  kubectl apply -f - <<EOF
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: ${TRAINJOB_NAME}
  namespace: ${TRAINJOB_NAMESPACE}
spec:
  trainer:
    numNodes: ${TRAINJOB_NUM_NODES}
    image: ${TRAINJOB_IMAGE}
    command:
      - python3
      - /opt/mnist/src/mnist.py
      - --epochs=1
    resourcesPerNode:
      requests:
        nvidia.com/gpu: 1
      limits:
        nvidia.com/gpu: 1
  runtimeRef:
    name: torch-distributed
    apiGroup: trainer.kubeflow.org
    kind: ClusterTrainingRuntime
EOF
  echo "::endgroup::"

  echo "::group::Wait for TrainJob completion (timeout ${TRAINJOB_TIMEOUT_SECONDS}s)"
  local deadline=$(( SECONDS + TRAINJOB_TIMEOUT_SECONDS ))
  local complete="" failed=""
  while (( SECONDS < deadline )); do
    complete="$(kubectl get trainjob "${TRAINJOB_NAME}" -n "${TRAINJOB_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(kubectl get trainjob "${TRAINJOB_NAME}" -n "${TRAINJOB_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [[ "${complete}" == "True" ]]; then
      echo "TrainJob Complete=True"
      break
    fi
    if [[ "${failed}" == "True" ]]; then
      echo "TrainJob Failed=True" >&2
      kubectl describe trainjob "${TRAINJOB_NAME}" -n "${TRAINJOB_NAMESPACE}" >&2 || true
      mkdir -p train-logs
      kubectl logs -n "${TRAINJOB_NAMESPACE}" -l "job-name=${TRAINJOB_NAME}-node-0" \
        --all-containers --tail=-1 > train-logs/"${TRAINJOB_NAME}".log 2>&1 || true
      exit 1
    fi
    sleep 15
  done
  if [[ "${complete}" != "True" ]]; then
    echo "TrainJob did not complete within ${TRAINJOB_TIMEOUT_SECONDS}s" >&2
    kubectl describe trainjob "${TRAINJOB_NAME}" -n "${TRAINJOB_NAMESPACE}" >&2 || true
    exit 1
  fi
  echo "::endgroup::"

  echo "::group::Capture TrainJob logs"
  mkdir -p train-logs
  kubectl logs -n "${TRAINJOB_NAMESPACE}" -l "job-name=${TRAINJOB_NAME}-node-0" \
    --all-containers --tail=-1 > train-logs/"${TRAINJOB_NAME}".log 2>&1 || true
  wc -l train-logs/"${TRAINJOB_NAME}".log || true
  echo "::endgroup::"
}

# serve_debug dumps the served-workload state (DGD, pods, describe, events,
# logs) into serve-logs/ and the step log so a failed or successful phase_serve
# is diagnosable from the uploaded artifacts. Best-effort; never fails the run.
serve_debug() {
  mkdir -p serve-logs
  {
    echo "--- dynamographdeployments ---"
    kubectl get dynamographdeployments -n "${SERVE_NAMESPACE}" -o yaml 2>&1 || true
    echo "--- pods ---"
    kubectl get pods -n "${SERVE_NAMESPACE}" -o wide 2>&1 || true
    echo "--- describe pods ---"
    kubectl describe pods -n "${SERVE_NAMESPACE}" 2>&1 || true
    echo "--- events ---"
    kubectl get events -n "${SERVE_NAMESPACE}" --sort-by=.lastTimestamp 2>&1 || true
    echo "--- logs (all pods, all containers, last 200 lines) ---"
    for p in $(kubectl get pods -n "${SERVE_NAMESPACE}" -o name 2>/dev/null); do
      echo "=== ${p} ==="
      kubectl logs -n "${SERVE_NAMESPACE}" "${p#pod/}" --all-containers --tail=200 2>&1 || true
    done
  } | tee serve-logs/"${SERVE_NAME}".log
}

phase_serve() {
  # Deploy the served inference graph (Dynamo) — the intent=inference CUJ, the
  # DC3 counterpart of phase_train. Mirrors the DynamoGraphDeployment in
  # demos/cuj2-inference.md (demos/workloads/inference/vllm-agg.yaml): the KAI
  # queue and a two-component (Frontend + decode Worker) graph serving an
  # OpenAI-compatible endpoint. The worker requests its GPU as a scalar
  # nvidia.com/gpu limit — the device-plugin production default (#1327).
  #
  # Tolerations are a portable SUPERSET of the taints across all UAT clusters
  # (AWS and GKE GPU pools use different `dedicated` values, the AKS pool carries
  # only nvidia.com/gpu; the DRA/gpu-operator adds nvidia.com/gpu). Tolerating a
  # taint a node does not carry is a no-op, so one list schedules correctly on
  # any of the clouds. The Frontend deliberately omits
  # the nvidia.com/gpu toleration so it stays OFF the scarce GPU nodes.
  echo "::group::Deploy DynamoGraphDeployment (${SERVE_NAME} in ${SERVE_NAMESPACE})"
  kubectl apply -f - <<EOF
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: ${SERVE_QUEUE}
spec:
  parentQueue: default-parent-queue
  resources:
    gpu: {limit: -1, overQuotaWeight: 1, quota: 0}
    cpu: {limit: -1, overQuotaWeight: 1, quota: 0}
    memory: {limit: -1, overQuotaWeight: 1, quota: 0}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${SERVE_NAMESPACE}
---
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeployment
metadata:
  name: ${SERVE_NAME}
  namespace: ${SERVE_NAMESPACE}
spec:
  backendFramework: vllm
  components:
    - name: Frontend
      type: frontend
      replicas: 1
      podTemplate:
        spec:
          tolerations:
            - {key: dedicated, operator: Equal, value: worker-workload, effect: NoSchedule}
            - {key: dedicated, operator: Equal, value: worker-workload, effect: NoExecute}
            - {key: dedicated, operator: Equal, value: gpu-workload, effect: NoSchedule}
            - {key: dedicated, operator: Equal, value: system-workload, effect: NoSchedule}
            - {key: dedicated, operator: Equal, value: system-workload, effect: NoExecute}
          containers:
            - name: main
              image: ${SERVE_RUNTIME_IMAGE}
              env:
                - {name: SERVED_MODEL_NAME, value: ${SERVE_MODEL}}
                - {name: DYN_ROUTER_MODE, value: kv}
    - name: VllmDecodeWorker
      type: worker
      replicas: 1
      sharedMemorySize: 2Gi
      podTemplate:
        spec:
          nodeSelector:
            ${SERVE_GPU_NODE_SELECTOR_KEY}: ${SERVE_GPU_NODE_SELECTOR_VALUE}
          tolerations:
            - {key: dedicated, operator: Equal, value: worker-workload, effect: NoSchedule}
            - {key: dedicated, operator: Equal, value: worker-workload, effect: NoExecute}
            - {key: dedicated, operator: Equal, value: gpu-workload, effect: NoSchedule}
            - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
          containers:
            - name: main
              image: ${SERVE_RUNTIME_IMAGE}
              workingDir: /workspace/examples/backends/vllm
              command: ["python3", "-m", "dynamo.vllm"]
              args:
                - --model
                - ${SERVE_MODEL}
                - --kv-events-config
                - '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5557"}'
              resources:
                limits:
                  nvidia.com/gpu: 1
EOF
  echo "::endgroup::"

  echo "::group::Wait for DynamoGraphDeployment readiness (timeout ${SERVE_READY_TIMEOUT_SECONDS}s)"
  # Expected pod count = sum of replicas across the graph's components (Frontend +
  # decode Worker = 2 here). Gating on "all pods Ready" alone races: the Frontend
  # pod is created and goes Ready seconds before the Dynamo operator materializes
  # the Worker, so `total == ready_count` is briefly true with only the Frontend
  # present — the readiness gate would pass, then serve traffic with no worker.
  # Require at least the declared component count of pods before certifying ready.
  local expected_pods
  # The `|| expected_pods=""` is load-bearing: this runs under `set -euo
  # pipefail`, so without it a transient kubectl/jq failure (API hiccup, CRD
  # registration lag) makes the pipeline non-zero, the assignment propagates it,
  # and errexit would kill the whole leg — with both stderr streams sent to
  # /dev/null — before the `expected_pods=2` fallback below could run. Tolerate
  # the read failure here so the fallback stays reachable.
  expected_pods="$(kubectl get dynamographdeployments.nvidia.com "${SERVE_NAME}" -n "${SERVE_NAMESPACE}" \
    -o json 2>/dev/null | jq '[.spec.components[]?.replicas // 1] | add // 0' 2>/dev/null)" || expected_pods=""
  # Fall back to the known-minimum (Frontend + Worker) on any read failure or an
  # under-count, so a transient hiccup can never relax the gate below two
  # components (fail-safe: the gate only ever tightens, never loosens).
  if [[ -z "${expected_pods}" || "${expected_pods}" -lt 2 ]]; then
    expected_pods=2
  fi
  echo "expecting ${expected_pods} workload pod(s) (sum of component replicas)"
  local deadline=$(( SECONDS + SERVE_READY_TIMEOUT_SECONDS ))
  local ready=false pods_json total ready_count
  while (( SECONDS < deadline )); do
    pods_json="$(kubectl get pods -n "${SERVE_NAMESPACE}" -o json 2>/dev/null || echo '{}')"
    # Fail closed as soon as a workload pod is unrecoverable so a bad image or
    # crash loop surfaces immediately instead of burning the whole readiness
    # budget. Two cases: a terminal phase=Failed, OR a container wedged in an
    # image-pull / crash-loop / config-error waiting state — the latter keep the
    # pod in phase=Running/Pending, so they must be checked explicitly (a
    # multi-GB vllm-runtime pull that 404s would otherwise wait out the full
    # SERVE_READY_TIMEOUT_SECONDS).
    bad="$(echo "${pods_json}" | jq -r '
      .items[]? as $p
      | ( [ ($p.status.containerStatuses // [])[]?, ($p.status.initContainerStatuses // [])[]?
            | .state.waiting.reason // empty ]
          + (if $p.status.phase == "Failed" then ["phase=Failed"] else [] end) )[]
      | select(. == "phase=Failed" or . == "ImagePullBackOff" or . == "ErrImagePull"
               or . == "CrashLoopBackOff" or . == "InvalidImageName"
               or . == "CreateContainerConfigError")' 2>/dev/null | head -n1)"
    if [[ -n "${bad}" ]]; then
      echo "a workload pod is unrecoverable (${bad}); not waiting out the readiness budget" >&2
      break
    fi
    # Ready when all expected component pods exist and every pod reports
    # Ready=True. Gating on expected_pods (not just total>0) closes the race
    # where the Frontend is Ready before the Worker pod is even created.
    total="$(echo "${pods_json}" | jq '[.items[]?] | length')"
    ready_count="$(echo "${pods_json}" | jq '[.items[]? | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')"
    if [[ "${total}" -ge "${expected_pods}" && "${total}" == "${ready_count}" ]]; then
      ready=true
      break
    fi
    echo "workload not ready (${ready_count}/${total} pods Ready, need ${expected_pods}); retrying in 15s..."
    sleep 15
  done
  echo "::endgroup::"

  if [[ "${ready}" != true ]]; then
    echo "::error::DynamoGraphDeployment ${SERVE_NAME} did not become ready within ${SERVE_READY_TIMEOUT_SECONDS}s" >&2
    echo "::group::Serve failure debug"
    serve_debug
    echo "::endgroup::"
    exit 1
  fi

  echo "::group::Query the OpenAI-compatible endpoint"
  local svc="${SERVE_NAME}-frontend"
  if ! kubectl get svc -n "${SERVE_NAMESPACE}" "${svc}" >/dev/null 2>&1; then
    echo "::error::frontend service ${svc} not found in ${SERVE_NAMESPACE}" >&2
    kubectl get svc -n "${SERVE_NAMESPACE}" >&2 || true
    echo "::endgroup::"
    exit 1
  fi
  # Port-forward the frontend and issue a sample chat completion. The forwarder
  # is a background child; kill it on every exit path so a failing assertion
  # does not leak the port-forward (belt-and-braces to the script exit, which
  # would also reap it).
  kubectl port-forward -n "${SERVE_NAMESPACE}" "svc/${svc}" \
    "${SERVE_FRONTEND_PORT}:${SERVE_FRONTEND_PORT}" >/dev/null 2>&1 &
  local pf_pid=$!
  local up=false resp="" rc=0
  for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:${SERVE_FRONTEND_PORT}/v1/models" >/dev/null 2>&1; then
      up=true
      break
    fi
    sleep 2
  done
  if [[ "${up}" == true ]]; then
    resp="$(curl -sS --max-time "${SERVE_REQUEST_TIMEOUT_SECONDS}" \
      -X POST "http://localhost:${SERVE_FRONTEND_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${SERVE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is Kubernetes?\"}],\"max_tokens\":64}")" || rc=$?
  fi
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
  echo "::endgroup::"

  if [[ "${up}" != true ]]; then
    echo "::error::frontend endpoint ${svc} did not accept connections within the port-forward window" >&2
    echo "::group::Serve failure debug"
    serve_debug
    echo "::endgroup::"
    exit 1
  fi
  echo "completion response:"
  echo "${resp}"
  # Assert a valid, non-empty OpenAI-compatible chat completion.
  if [[ "${rc}" -ne 0 ]] || \
     ! echo "${resp}" | jq -e '.choices[0].message.content | type == "string" and (length > 0)' >/dev/null 2>&1; then
    echo "::error::inference request did not return a valid chat completion (curl rc=${rc})" >&2
    echo "::group::Serve failure debug"
    serve_debug
    echo "::endgroup::"
    exit 1
  fi
  echo "served inference OK: /v1/chat/completions returned a non-empty completion"

  echo "::group::Capture serve logs"
  serve_debug >/dev/null
  wc -l serve-logs/"${SERVE_NAME}".log || true
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# Single-cluster reuse phases (session mode). When a reservation opts into
# nightly-reuse-cluster, ONE cluster is provisioned per batch and every
# (version x intent) cell runs against it. Between cells the AICR stack must be
# uninstalled and the GPU nodes recycled, and before each cell installs the
# cluster must be proven a valid from-scratch target — otherwise a cell would
# validate an already-converged stack and record a FALSE pass. These phases
# codify the software side (uninstall / freshness proof / k8s compatibility);
# the cloud-specific GPU-node recycle + node-freshness proof live in
# .github/scripts/uat-<cloud>-recycle-gpu.sh.
# ---------------------------------------------------------------------------

# ns_is_protected reports (exit 0) whether a namespace must never be deleted by
# the uninstall sweep. The candidate list is bundle-derived (helmfile), but a
# component chart could render into a cloud-managed namespace, so this is an
# explicit refusal set rather than a best-effort filter: system namespaces, and
# the cloud add-on prefixes each provider reconciles on its own.
ns_is_protected() {
  local ns="$1"
  case "${ns}" in
    default|kube-system|kube-public|kube-node-lease) return 0 ;;
    kube-*|gke-*|gmp-*|gatekeeper-*|calico-*|tigera-*|azure-*|aks-*|kalico-*) return 0 ;;
    *) return 1 ;;
  esac
}

# phase_uninstall removes the AICR-deployed stack so the next cell installs from
# a clean slate:
#
#   1. the gpu-operator ClusterPolicy is deleted FIRST, while the operator that
#      owns its finalizer is still running (deleting it after `helmfile destroy`
#      leaves the CR wedged in Terminating forever, which then blocks the next
#      gpu-operator install — the exact orphan this step exists to prevent);
#   2. `helmfile destroy` removes the helm releases;
#   3. cluster-scoped residue helm never reaps (webhook configurations,
#      APIServices) is swept by helm's own ownership labels — a leaked webhook
#      whose backing Service is gone rejects cluster-wide creates on the next
#      install;
#   4. the release namespaces are deleted to reap StatefulSet PVCs.
#
# Sweep failures are surfaced (not silently swallowed) and phase_guard_fresh is
# the fail-closed backstop that refuses to install onto a dirty cluster.
phase_uninstall() {
  command -v helmfile >/dev/null || { echo "helmfile not on PATH" >&2; exit 1; }
  if [[ ! -f bundle/helmfile.yaml ]]; then
    # A cell that failed before prep produced no bundle and deployed nothing;
    # the recycle + guard still run, so the next cell starts clean regardless.
    echo "no bundle/helmfile.yaml in ${PWD}; nothing to helmfile-destroy (run prep first)"
    return 0
  fi

  # Capture release namespaces BEFORE destroy so leftover StatefulSet PVCs can
  # be reaped afterward (helm uninstall does not delete them). A FAILURE to
  # enumerate must be loud: silently yielding an empty list would skip the whole
  # namespace/PVC sweep while the phase still reported success.
  local namespaces=() helmfile_json="" list_rc=0
  helmfile_json="$( ( cd bundle && helmfile list --output json ) 2>/dev/null )" || list_rc=$?
  if (( list_rc != 0 )) || [[ -z "${helmfile_json}" ]]; then
    echo "::warning::could not enumerate helm releases (helmfile list rc=${list_rc}); the namespace/PVC sweep will be skipped and guard-fresh must catch any residue" >&2
  else
    mapfile -t namespaces < <(jq -r '.[].namespace // empty' <<<"${helmfile_json}" | sort -u)
  fi

  # (1) ClusterPolicy BEFORE destroy, while the operator can process its
  # finalizer. Guarded on the CRD's presence so it no-ops when gpu-operator was
  # never installed.
  if kubectl get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
    echo "::group::Delete gpu-operator ClusterPolicy (pre-destroy, operator still running)"
    kubectl delete clusterpolicies.nvidia.com --all --ignore-not-found --timeout=120s \
      || echo "::warning::ClusterPolicy delete did not complete; a finalizer strip is attempted after destroy"
    echo "::endgroup::"
  fi

  # (2) Remove the releases.
  echo "::group::helmfile destroy"
  ( cd bundle && timeout "${UNINSTALL_TIMEOUT_SECONDS}" helmfile destroy ) \
    || echo "::warning::helmfile destroy returned non-zero; continuing to explicit sweep (guard-fresh fails closed if the cluster is not clean)"
  echo "::endgroup::"

  # Backstop: if a ClusterPolicy still exists after destroy its finalizer can no
  # longer be processed (the operator is gone), so strip it explicitly rather
  # than leaving a Terminating singleton that blocks the next install.
  if kubectl get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
    local stuck
    stuck="$(kubectl get clusterpolicies.nvidia.com -o name 2>/dev/null || true)"
    if [[ -n "${stuck}" ]]; then
      echo "::group::Strip orphaned ClusterPolicy finalizers"
      while IFS= read -r cp; do
        [[ -z "${cp}" ]] && continue
        echo "stripping finalizers from ${cp} (operator no longer running to process them)"
        kubectl patch "${cp}" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
        kubectl delete "${cp}" --ignore-not-found --timeout=60s || true
      done <<<"${stuck}"
      echo "::endgroup::"
    fi
  fi

  # (3) Cluster-scoped residue helm leaves behind. Selected by helm's OWN
  # ownership labels/annotations and restricted to this bundle's release
  # namespaces, so nothing outside what AICR deployed is ever targeted.
  if (( ${#namespaces[@]} > 0 )); then
    echo "::group::Sweep cluster-scoped residue (webhooks, APIServices)"
    local ns_filter kind obj
    ns_filter="$(printf '%s\n' "${namespaces[@]}" | jq -R . | jq -cs .)"
    for kind in validatingwebhookconfigurations mutatingwebhookconfigurations apiservices; do
      while IFS= read -r obj; do
        [[ -z "${obj}" ]] && continue
        echo "deleting ${kind}/${obj} (helm-owned, release namespace in this bundle)"
        kubectl delete "${kind}" "${obj}" --ignore-not-found --timeout=60s || true
      done < <(kubectl get "${kind}" \
                 -l app.kubernetes.io/managed-by=Helm -o json 2>/dev/null \
               | jq -r --argjson ns "${ns_filter}" \
                   '.items[]? | select((.metadata.annotations["meta.helm.sh/release-namespace"] // "") as $rns | $ns | index($rns)) | .metadata.name' \
                 2>/dev/null || true)
    done
    echo "::endgroup::"
  fi

  # (4) Delete the release namespaces to reap StatefulSet PVCs and any namespaced
  # residue, bounded so a stuck finalizer cannot hang the phase past its budget.
  # Protected namespaces are refused explicitly (see ns_is_protected).
  if (( ${#namespaces[@]} > 0 )); then
    local deletable=() ns
    for ns in "${namespaces[@]}"; do
      if ns_is_protected "${ns}"; then
        echo "::warning::refusing to delete protected namespace ${ns} (a chart rendered into it); sweep it by hand if it holds AICR residue"
        continue
      fi
      deletable+=("${ns}")
    done
    if (( ${#deletable[@]} > 0 )); then
      echo "::group::Delete release namespaces (${deletable[*]})"
      kubectl delete namespace "${deletable[@]}" --ignore-not-found \
        --timeout="${NAMESPACE_DELETE_TIMEOUT_SECONDS}s" \
        || echo "::warning::namespace deletion did not finish within budget; guard-fresh will assess residue"
      echo "::endgroup::"
    fi
  fi
}

# phase_guard_fresh FAILS CLOSED unless the shared session cluster is a valid
# from-scratch-install target. It asserts AICR-OWNED state rather than a derived
# platform signal:
#
#   * the gpu-worker nodes are present and Ready;
#   * no helm releases survive in the bundle's release namespaces;
#   * no gpu-operator ClusterPolicy CR exists (a Terminating one blocks install);
#   * no nvidia device-plugin / driver DaemonSet pods are still running outside
#     the platform's own namespaces.
#
# It deliberately does NOT key on `allocatable["nvidia.com/gpu"]` by default.
# That signal only proves "the AICR GPU stack is down" on clouds where AICR owns
# the device plugin: GKE (`gpuDriverInstallation: DEFAULT`) and AKS
# (`gpuDriverInstall: true`) have the PLATFORM install the driver and its own
# device-plugin DaemonSet, so a freshly provisioned or freshly recycled node
# advertises nvidia.com/gpu with zero AICR components installed and the gate
# would never converge. A cloud whose runner knows the platform ships no device
# plugin opts the stricter check in via GUARD_REQUIRE_NO_GPU_ADVERTISED=true
# (see tests/uat/aws/run), mirroring the cloud_refresh_credentials hook pattern.
#
# The clean state must hold for GUARD_CONSECUTIVE_PASSES consecutive
# observations: a single observation cannot distinguish "clean" from "the
# leftover DaemonSet has not been rescheduled onto the new nodes yet", the same
# reason phase_install requires consecutive readiness passes.
#
# (Node-level freshness — that the GPU nodes were replaced with clean-boot
# instances, clearing driver/kernel tuning — is asserted by the recycle script;
# this phase asserts the SOFTWARE side, portably across clouds.)
phase_guard_fresh() {
  echo "::group::Freshness guard"
  local deadline=$(( SECONDS + GUARD_TIMEOUT_SECONDS ))
  local nodes_json gpu_nodes ready_gpu gpu_advertised releases clusterpolicies plugin_pods
  local streak=0 reason=""
  while :; do
    reason=""
    # A transient API error must not abort the phase: the retry loop exists to
    # ride out exactly this, so treat a failed read as "not yet" and re-poll.
    if ! nodes_json="$(kubectl get nodes -o json 2>/dev/null)"; then
      reason="kubectl get nodes failed (transient?)"
      nodes_json=""
    fi

    if [[ -z "${reason}" ]]; then
      # Every UAT cluster-config labels its GPU pool nodeGroup=gpu-worker.
      gpu_nodes="$(jq '[.items[] | select(.metadata.labels["nodeGroup"] == "gpu-worker")] | length' <<<"${nodes_json}")"
      ready_gpu="$(jq '[.items[] | select(.metadata.labels["nodeGroup"] == "gpu-worker") | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length' <<<"${nodes_json}")"
      if (( gpu_nodes < 1 )); then
        reason="no gpu-worker nodes present"
      elif [[ "${ready_gpu}" != "${gpu_nodes}" ]]; then
        reason="gpu-worker Ready ${ready_gpu}/${gpu_nodes}"
      fi
    fi

    # No surviving helm releases anywhere outside the platform namespaces. This
    # is the portable, AICR-owned proof that the stack is gone.
    if [[ -z "${reason}" ]]; then
      releases="$(helm list -A -o json 2>/dev/null \
        | jq -r '[.[]? | select(.namespace | test("^(kube-|gke-|gmp-|calico-|tigera-|azure-|aks-|default$)") | not) | .name] | length' 2>/dev/null || echo "unknown")"
      if [[ "${releases}" == "unknown" ]]; then
        reason="could not list helm releases (transient?)"
      elif [[ "${releases}" != "0" ]]; then
        reason="${releases} helm release(s) still installed"
      fi
    fi

    # A ClusterPolicy (even Terminating) blocks the next gpu-operator install.
    if [[ -z "${reason}" ]] && kubectl get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
      clusterpolicies="$(kubectl get clusterpolicies.nvidia.com -o name 2>/dev/null | grep -c . || true)"
      if [[ "${clusterpolicies}" != "0" ]]; then
        reason="${clusterpolicies} gpu-operator ClusterPolicy CR(s) still present"
      fi
    fi

    # Any surviving AICR-deployed device-plugin/driver pod means the runtime is
    # still up even if it has not yet re-advertised the resource.
    if [[ -z "${reason}" ]]; then
      plugin_pods="$(kubectl get pods -A -o json 2>/dev/null \
        | jq -r '[.items[]? | select(.metadata.namespace | test("^(kube-|gke-|gmp-|calico-|tigera-|azure-|aks-)") | not) | select(.metadata.name | test("nvidia-device-plugin|nvidia-driver-daemonset|gpu-feature-discovery"))] | length' 2>/dev/null || echo "0")"
      if [[ "${plugin_pods}" != "0" ]]; then
        reason="${plugin_pods} AICR GPU runtime pod(s) still running"
      fi
    fi

    # Opt-in strict check for clouds where the platform ships no device plugin.
    if [[ -z "${reason}" && "${GUARD_REQUIRE_NO_GPU_ADVERTISED}" == "true" && -n "${nodes_json}" ]]; then
      gpu_advertised="$(jq '[.items[] | select(.status.allocatable["nvidia.com/gpu"] != null)] | length' <<<"${nodes_json}")"
      if [[ "${gpu_advertised}" != "0" ]]; then
        reason="${gpu_advertised} node(s) still advertise nvidia.com/gpu"
      fi
    fi

    if [[ -z "${reason}" ]]; then
      streak=$(( streak + 1 ))
      if (( streak >= GUARD_CONSECUTIVE_PASSES )); then
        echo "freshness guard passed: ${gpu_nodes} gpu-worker node(s) Ready, AICR GPU runtime not deployed (${streak} consecutive clean observations)"
        echo "::endgroup::"
        return 0
      fi
      echo "cluster looks clean (${streak}/${GUARD_CONSECUTIVE_PASSES} consecutive); re-checking in 15s..."
    else
      # Any regression invalidates the streak — the cluster must be STABLY clean.
      if (( streak > 0 )); then
        echo "clean streak broken after ${streak} observation(s): ${reason}"
      fi
      streak=0
      echo "cluster not yet a clean from-scratch target (${reason}); retrying in 15s..."
    fi

    if (( SECONDS >= deadline )); then
      echo "::error::freshness guard: cluster is not a stably clean from-scratch target within ${GUARD_TIMEOUT_SECONDS}s (last: ${reason:-clean but only ${streak}/${GUARD_CONSECUTIVE_PASSES} consecutive}); refusing to install (would risk a false pass or an unready pool)" >&2
      kubectl get nodes -o wide --show-labels >&2 || true
      helm list -A >&2 || true
      echo "::endgroup::"
      exit 1
    fi
    sleep 15
  done
}

# k8s_version_normalize strips a leading v and any pre-release/build suffix
# ("v1.35.0-eks-abc" -> "1.35.0") and pads to X.Y.Z so a 2-component constraint
# token (">= 1.32", "1.35") compares cleanly against a 3-component cluster
# version ("1.35.0"): missing minor/patch components default to 0.
k8s_version_normalize() {
  local v="${1#v}"
  v="${v%%-*}"  # drop -eks... / -gke... / pre-release
  v="${v%%+*}"  # drop +build metadata
  local maj min pat IFS=.
  read -r maj min pat _ <<<"${v}"
  printf '%s.%s.%s' "${maj:-0}" "${min:-0}" "${pat:-0}"
}

# k8s_version_cmp prints -1 / 0 / 1 for a<b / a==b / a>b using version sort.
k8s_version_cmp() {
  local a b
  a="$(k8s_version_normalize "$1")"
  b="$(k8s_version_normalize "$2")"
  if [[ "${a}" == "${b}" ]]; then printf '0'; return; fi
  if [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${a}" ]]; then
    printf -- '-1'
  else
    printf '1'
  fi
}

# k8s_version_satisfies_clause reports (exit 0/1) whether cluster version $1
# satisfies ONE semver clause $2 (">= 1.32", "!= 1.34", "1.35", ...). The
# operator set mirrors pkg/constraints (GTE, LTE, GT, LT, EQ, NE, exact) so the
# bash gate and the Go evaluator agree on every operator a recipe can express.
# An unrecognized operator (~, ^, x-ranges) returns non-zero -> fail closed.
k8s_version_satisfies_clause() {
  local ver="$1" clause op want cmp
  clause="$(printf '%s' "$2" | tr -s '[:space:]' ' ')"
  clause="${clause# }"
  clause="${clause% }"
  case "${clause}" in
    ">="*) op=">="; want="${clause#>=}" ;;
    "<="*) op="<="; want="${clause#<=}" ;;
    "!="*) op="!="; want="${clause#!=}" ;;
    ">"*)  op=">";  want="${clause#>}" ;;
    "<"*)  op="<";  want="${clause#<}" ;;
    "=="*) op="=";  want="${clause#==}" ;;
    "="*)  op="=";  want="${clause#=}" ;;
    [0-9v]*) op="="; want="${clause}" ;;
    *) return 1 ;;  # unknown operator -> fail closed
  esac
  want="${want//[[:space:]]/}"
  # Only a bare vX[.Y[.Z]] token is evaluable; anything else (an x-range,
  # garbage) is unsupported -> fail closed.
  [[ "${want}" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  cmp="$(k8s_version_cmp "${ver}" "${want}")"
  case "${op}" in
    ">=") [[ "${cmp}" != "-1" ]] ;;
    ">")  [[ "${cmp}" == "1" ]] ;;
    "<=") [[ "${cmp}" != "1" ]] ;;
    "<")  [[ "${cmp}" == "-1" ]] ;;
    "=")  [[ "${cmp}" == "0" ]] ;;
    "!=") [[ "${cmp}" != "0" ]] ;;
    *) return 1 ;;
  esac
}

# k8s_version_satisfies reports (exit 0/1) whether cluster version $1 satisfies
# constraint $2. A COMPOUND constraint (comma-joined clauses, e.g.
# ">= 1.32, < 1.36") is satisfied only when EVERY clause is — matching the
# conjunction semantics of the Go evaluator — so a legitimate range no longer
# hard-fails the cell. An empty constraint, or any clause with an unsupported
# operator, returns non-zero -> fail closed (the caller fails the cell rather
# than reusing a cluster it could not prove compatible).
k8s_version_satisfies() {
  local ver="$1" constraint="$2" clause
  [[ -z "${constraint//[[:space:]]/}" ]] && return 1
  local IFS=','
  for clause in ${constraint}; do
    [[ -z "${clause//[[:space:]]/}" ]] && continue
    k8s_version_satisfies_clause "${ver}" "${clause}" || return 1
  done
  return 0
}

# phase_compat decides whether the shared session cluster satisfies THIS cell's
# recipe. It resolves the recipe (criteria -> constraints) and compares the
# recipe's K8s.server.version constraint against the live cluster's server
# version. Exit 0 = compatible (reuse the session cluster); exit
# COMPAT_EXIT_INCOMPATIBLE = incompatible — the pipeline fails the cell (a
# genuine incompatibility signal; the reservation's single cluster-config could
# not be reprovisioned into a satisfying shape anyway). FAILS CLOSED to
# incompatible on any ambiguity.
phase_compat() {
  echo "::group::Resolve recipe for compatibility check"
  "${AICR_BIN}" recipe --config "${config}"
  test -f recipe.yaml
  echo "::endgroup::"

  # Read the constraint WITHOUT swallowing yq's stderr: a malformed recipe.yaml
  # must not silently read as "no constraint declared", which would pass the gate
  # (fail OPEN) in a function whose whole contract is fail-closed.
  local constraints=() cluster_ver constraint yq_rc=0 yq_out=""
  yq_out="$(yq -r '.constraints[]? | select(.name == "K8s.server.version") | .value' recipe.yaml)" || yq_rc=$?
  if (( yq_rc != 0 )); then
    echo "::error::could not read constraints from recipe.yaml (yq rc=${yq_rc}); failing closed" >&2
    exit "${COMPAT_EXIT_INCOMPATIBLE}"
  fi
  mapfile -t constraints < <(grep -v '^null$' <<<"${yq_out}" | grep -v '^$' || true)

  cluster_ver="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"

  if (( ${#constraints[@]} == 0 )); then
    echo "recipe declares no K8s.server.version constraint — session cluster is compatible"
    return 0
  fi
  # Recipe merging collapses same-named constraints, so >1 here means the
  # resolver changed shape. Picking one (previously `head -n1`) could silently
  # evaluate the LAXER of two and reuse a cluster the stricter one forbids —
  # fail closed instead.
  if (( ${#constraints[@]} > 1 )); then
    echo "::error::recipe declares ${#constraints[@]} K8s.server.version constraints (${constraints[*]}); expected exactly one after merge — failing closed rather than guessing which applies" >&2
    exit "${COMPAT_EXIT_INCOMPATIBLE}"
  fi
  constraint="${constraints[0]}"
  echo "recipe K8s.server.version constraint: '${constraint}'; cluster server version: '${cluster_ver:-<unknown>}'"

  if [[ -z "${cluster_ver}" ]]; then
    echo "::error::could not read cluster server version; failing closed" >&2
    exit "${COMPAT_EXIT_INCOMPATIBLE}"
  fi
  if k8s_version_satisfies "${cluster_ver}" "${constraint}"; then
    echo "session cluster ${cluster_ver} satisfies '${constraint}' — compatible"
    return 0
  fi
  echo "::error::session cluster ${cluster_ver} does NOT satisfy recipe constraint '${constraint}' — this reservation's cluster shape cannot run this cell (genuine incompatibility); failing the cell" >&2
  exit "${COMPAT_EXIT_INCOMPATIBLE}"
}

# phase_recycle replaces the GPU nodes with clean-boot instances between cells on
# a shared session cluster, via the per-cloud cloud_recycle_gpu_nodes hook. The
# value of the UAT is validating a FROM-SCRATCH GPU-runtime deploy (driver
# install, skyhook tuning, and the reboots they trigger); a node the previous
# cell already tuned would let the readiness gate pass trivially — a false pass.
phase_recycle() {
  echo "::group::Recycle GPU nodes"
  if ! cloud_recycle_gpu_nodes; then
    echo "::error::GPU-node recycle failed; the session cluster is NOT a valid target for the next cell" >&2
    echo "::endgroup::"
    exit 1
  fi
  echo "::endgroup::"
}

phase_verify() {
  echo "::group::Bootstrap Sigstore TUF root"
  "${AICR_BIN}" trust update
  echo "::endgroup::"

  # Pin the expected signer when EXPECTED_ISSUER / EXPECTED_IDENTITY_REGEXP
  # are set (CI sets them to the workflow's OIDC identity). Without pinning,
  # any Fulcio-signed payload would pass verification — useful for local
  # dev where the signing identity is the user, mandatory in CI.
  local args=(evidence verify ./evidence/pointer.yaml)
  if [[ -n "${EXPECTED_ISSUER:-}" ]]; then
    args+=(--expected-issuer "${EXPECTED_ISSUER}")
  fi
  if [[ -n "${EXPECTED_IDENTITY_REGEXP:-}" ]]; then
    args+=(--expected-identity-regexp "${EXPECTED_IDENTITY_REGEXP}")
  fi
  args+=(-o evidence-result.json -t json)

  echo "::group::Verify signed evidence bundle"
  # Capture the exit code instead of letting `set -e` abort here: on a
  # verification failure the binary exits non-zero, which would kill the script
  # before the diagnostic `cat evidence-result.json` below ever ran and would
  # leave the ::group:: unclosed. Print the result, then propagate the status.
  local vrc=0
  "${AICR_BIN}" "${args[@]}" || vrc=$?
  echo "::endgroup::"

  if (( vrc != 0 )); then
    echo "::error::evidence verify exited ${vrc}" >&2
    cat evidence-result.json 2>/dev/null || true
    exit "${vrc}"
  fi

  local exit_code
  exit_code="$(jq -r '.exit' evidence-result.json)"
  echo "evidence verify exit code: ${exit_code}"
  if [[ "${exit_code}" != "0" ]]; then
    cat evidence-result.json
    exit 1
  fi
}

# uat_main parses args, validates required env, and dispatches to the requested
# phase. Called by each per-cloud runner as `uat_main "$@"`. phase/config are
# declared local here but remain visible to the phase functions via bash dynamic
# scoping (the functions read ${config}).
uat_main() {
  local phase="${1:-}" config="${2:-}"

  if [[ -z "${phase}" || -z "${config}" ]]; then
    echo "Usage: $0 <phase> <test-config.yaml>" >&2
    echo "Phases: prep | install | conformance | train | serve | verify | debug | compat | guard-fresh | uninstall | recycle | session-cell | all" >&2
    exit 2
  fi

  if [[ ! -f "${config}" ]]; then
    echo "test-config not found: ${config}" >&2
    exit 2
  fi

  : "${AICR_BIN:?Set AICR_BIN to the path of the aicr binary}"
  : "${RUN_ID:?Set RUN_ID (workflow passes \${{ github.run_id }}; locally use local-\$(date +%s))}"

  case "${phase}" in
    prep)        phase_prep ;;
    install)     phase_install ;;
    conformance) phase_conformance ;;
    train)       phase_train ;;
    serve)       phase_serve ;;
    verify)      phase_verify ;;
    compat)      phase_compat ;;
    guard-fresh) phase_guard_fresh ;;
    uninstall)   phase_uninstall ;;
    recycle)     phase_recycle ;;
    session-cell)
      # The full between-provision cell a reuse batch runs against a shared
      # session cluster, in order — the local-reproduction counterpart of `all`.
      phase_compat; phase_guard_fresh; phase_prep; phase_install; phase_conformance
      intent="$(yq -r '.spec.recipe.criteria.intent // "training"' "${config}")"
      case "${intent}" in
        inference) phase_serve ;;
        *)         phase_train ;;
      esac
      phase_verify; phase_uninstall; phase_recycle
      ;;
    debug)
      # Refresh cloud credentials first (no-op on AWS/GCP; Azure redeems a fresh
      # federated session). A failure that surfaces after a long phase can leave a
      # dead credential, which would make every kubectl in the collector no-op and
      # the bundle come out silently empty — so warn (don't abort) on failure
      # rather than swallowing it, so a truncated bundle is explained.
      cloud_refresh_credentials || echo "::warning::cloud credential refresh failed before debug collection; the bundle may come out empty" >&2
      collect_cluster_debug
      ;;
    all)
      # The CUJ phase is chosen by the config's recipe intent so `run all`
      # reproduces the right end-to-end flow: serve for inference, train
      # otherwise. Defaults to training if the intent is unset.
      phase_prep; phase_install; phase_conformance
      intent="$(yq -r '.spec.recipe.criteria.intent // "training"' "${config}")"
      case "${intent}" in
        inference) phase_serve ;;
        *)         phase_train ;;
      esac
      phase_verify
      ;;
    *)
      echo "unknown phase: ${phase}" >&2
      echo "Phases: prep | install | conformance | train | serve | verify | debug | compat | guard-fresh | uninstall | recycle | session-cell | all" >&2
      exit 2
      ;;
  esac
}
