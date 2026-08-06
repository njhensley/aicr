#!/bin/bash
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

# onboarding.sh — the AICR four-stage workflow, end to end, on a laptop.
#
# This is the live-demo companion to demos/onboarding.md (the facilitator guide)
# and demos/onboarding-slides.html (the deck). It walks the whole model in a
# handful of commands and needs NO cluster and NO credentials by default:
#
#   Recipe   (from criteria)  -> aicr recipe
#   Inspect  (asymmetric match)-> aicr recipe | yq .metadata.appliedOverlays
#   Query    (one value)       -> aicr query --selector ...
#   Bundle   (a deployer)      -> aicr bundle --deployer helm
#   Verify   (trust ladder)    -> aicr verify ./bundle [--min-trust-level verified]
#   Validate (offline)         -> aicr validate --no-cluster (against a mock snapshot)
#
# Every step pauses first (unless DEMO_NO_PAUSE=1) and streams the FULL output of
# each aicr command — nothing is suppressed or captured silently.
#
# Usage:  ./demos/onboarding.sh
#
# All configuration is via environment variables; every knob has a default:
#
#   AICR=/path/to/aicr        aicr binary (default: aicr on PATH)
#   WORKDIR=/tmp/aicr-...      scratch dir for recipe/bundle (default below)
#
#   # recipe criteria — defaults resolve the EKS H100 Ubuntu training + kubeflow
#   # recipe, which is exactly what the bundled offline mock snapshot covers.
#   SERVICE=eks  ACCELERATOR=h100  OS=ubuntu  INTENT=training  PLATFORM=kubeflow
#
#   # offline validate: a snapshot to evaluate constraints against without a
#   # cluster. Defaults to the repo's mock snapshot when run from a checkout.
#   SNAPSHOT=/path/to/snapshot.yaml
#
#   DEMO_NO_PAUSE=1            unattended: skip all the "Press Enter" prompts
#   NO_COLOR=1                 disable ANSI color

set -euo pipefail

# --- configuration -----------------------------------------------------------

AICR="${AICR:-aicr}"
WORKDIR="${WORKDIR:-/tmp/aicr-onboarding-demo}"

SERVICE="${SERVICE:-eks}"
ACCELERATOR="${ACCELERATOR:-h100}"
OS="${OS:-ubuntu}"
INTENT="${INTENT:-training}"
PLATFORM="${PLATFORM:-kubeflow}"

# Resolve this script's directory so we can find the repo's mock snapshot even
# when invoked from elsewhere. Falls back gracefully if run outside a checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SNAPSHOT="$SCRIPT_DIR/../tests/chainsaw/cli/cuj1-training/mock-snapshot.yaml"
SNAPSHOT="${SNAPSHOT:-$DEFAULT_SNAPSHOT}"

# --- presentation helpers -----------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi

STEP=0

# banner <title> — prints a numbered section header.
banner() {
  STEP=$((STEP + 1))
  printf '\n%s========================================================================%s\n' "$CYAN" "$RESET"
  printf '%sSTEP %s: %s%s\n' "$BOLD" "$STEP" "$1" "$RESET"
  printf '%s========================================================================%s\n' "$CYAN" "$RESET"
}

# note <text> — prints an explanatory line.
note() { printf '%s%s%s\n' "$DIM" "$1" "$RESET"; }

# pause [prompt] — waits for Enter. Reads from the terminal directly so it works
# even when the script's stdin is piped. Honors DEMO_NO_PAUSE=1 for unattended runs.
pause() {
  local prompt="${1:-Press Enter to continue...}"
  if [ "${DEMO_NO_PAUSE:-0}" = "1" ]; then return 0; fi
  printf '\n%s▶ %s%s ' "$YELLOW" "$prompt" "$RESET"
  if [ -r /dev/tty ]; then read -r _ </dev/tty; else read -r _ || true; fi
}

# run <cmd...> — echoes the command, then runs it with output streaming straight
# to the terminal (never suppressed). Aborts on failure.
run() {
  printf '\n%s$ %s%s\n' "$GREEN" "$*" "$RESET"
  "$@"
  local rc=$?
  printf '%s[exit %s]%s\n' "$DIM" "$rc" "$RESET"
  return "$rc"
}

# run_expect_fail <cmd...> — like run(), but a NON-zero exit is the expected,
# successful outcome (e.g. a deploy gate refusing an unsigned bundle). Output is
# still streamed in full.
run_expect_fail() {
  printf '\n%s$ %s%s\n' "$GREEN" "$*" "$RESET"
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s[exit %s — expected failure ✓]%s\n' "$GREEN" "$rc" "$RESET"
    return 0
  else
    printf '%s[exit 0 — UNEXPECTED: command was supposed to fail]%s\n' "$RED" "$RESET"
    return 1
  fi
}

# show_field <file> <yq-path> <grep-fallback> — pretty-print a recipe field,
# preferring yq when present so we don't hard-depend on it.
show_field() {
  local file="$1" path="$2" grepkey="$3"
  if command -v yq >/dev/null 2>&1; then
    run yq "$path" "$file"
  else
    note "(yq not found — showing the raw '$grepkey' block from $file)"
    run grep -nA25 "$grepkey" "$file"
  fi
}

# --- preflight ----------------------------------------------------------------

banner "Preflight — environment & aicr version"
note "Binary:     $AICR"
note "Workdir:    $WORKDIR"
note "Criteria:   service=$SERVICE accelerator=$ACCELERATOR os=$OS intent=$INTENT platform=$PLATFORM"
note "Snapshot:   $SNAPSHOT"
note ""
note "This demo is LAPTOP-ONLY: no cluster, no credentials. It resolves recipes"
note "against the embedded catalog and validates against a mock snapshot offline."

if ! command -v "$AICR" >/dev/null 2>&1 && [ ! -x "$AICR" ]; then
  printf '%sERROR: aicr binary not found at %q. Install it: curl -sfL https://get.aicr.run | bash -s --%s\n' "$RED" "$AICR" "$RESET" >&2
  exit 1
fi

mkdir -p "$WORKDIR"
RECIPE="$WORKDIR/recipe.yaml"
RECIPE_BROAD="$WORKDIR/recipe-broad.yaml"
BUNDLE="$WORKDIR/bundle"

run "$AICR" --version
pause

# --- stage 2: recipe (from criteria) -----------------------------------------

banner "Recipe — resolve a version-locked config from criteria"
note "No cluster needed: the recipe engine matches your criteria against a library"
note "of validated overlays + mixins and emits a fully-hydrated, pinned config."
recipe_args=(recipe --service "$SERVICE" --accelerator "$ACCELERATOR" --os "$OS" --intent "$INTENT")
[ -n "$PLATFORM" ] && recipe_args+=(--platform "$PLATFORM")
recipe_args+=(--output "$RECIPE")
pause "Press Enter to resolve the recipe"
run "$AICR" "${recipe_args[@]}"
note "Wrote $RECIPE"
pause

# --- inspect: asymmetric matching --------------------------------------------

banner "Inspect — which overlays merged (asymmetric matching)"
note "appliedOverlays shows the inheritance chain that produced this recipe:"
note "base -> service -> intent -> accelerator -> os (+ mixins)."
show_field "$RECIPE" '.metadata.appliedOverlays' 'appliedOverlays'
pause "Press Enter to contrast with a GENERIC query"

note "Now a broad query with ONLY --service eks. Asymmetric matching means a"
note "generic query can NEVER silently resolve to a hardware-specific recipe —"
note "watch how few overlays apply compared to the specific query above."
run "$AICR" recipe --service "$SERVICE" --output "$RECIPE_BROAD"
show_field "$RECIPE_BROAD" '.metadata.appliedOverlays' 'appliedOverlays'
pause

# --- inspect: deployment order -----------------------------------------------

banner "Inspect — deployment order (topological sort over dependencies)"
note "deploymentOrder is a Kahn topological sort over each component's"
note "dependencyRefs; independent components can deploy in parallel."
show_field "$RECIPE" '.deploymentOrder' 'deploymentOrder'
pause

# --- stage: query one hydrated value -----------------------------------------

banner "Query — pull ONE hydrated value (great for IaC vars)"
note "No need to render the whole bundle to read a single resolved value."
query_args=(query --service "$SERVICE" --accelerator "$ACCELERATOR" --os "$OS" --intent "$INTENT")
[ -n "$PLATFORM" ] && query_args+=(--platform "$PLATFORM")
query_args+=(--selector components.gpu-operator.values.driver.version)
pause "Press Enter to query the resolved GPU driver version"
run "$AICR" "${query_args[@]}"
pause

# --- stage 4: bundle ----------------------------------------------------------

banner "Bundle — materialize the recipe for a deployer"
note "The SAME validated recipe re-renders for helm / argocd / argocd-helm /"
note "flux / helmfile. Here we emit the default (helm): one folder per component"
note "with values, checksums, and a deploy.sh — no cluster touched."
rm -rf "$BUNDLE"
pause "Press Enter to generate the bundle"
run "$AICR" bundle --recipe "$RECIPE" --deployer helm --output "$BUNDLE"
note "Bundle contents:"
if command -v tree >/dev/null 2>&1; then run tree -L 2 "$BUNDLE"; else run ls -la "$BUNDLE"; fi
pause

# --- stage: verify (the trust ladder) ----------------------------------------

banner "Verify — the 4-level trust ladder"
note "aicr verify computes a trust level: verified(4) > attested(3) >"
note "unverified(2) > unknown(1). This bundle is UNSIGNED (no --attest), so the"
note "default verify passes at 'unverified' — it checks the closed-world"
note "inventory but there is no attestation to raise it higher."
run "$AICR" verify "$BUNDLE"
pause "Press Enter to see a real deploy GATE reject it"

note "A deploy gate should demand 'verified'. Because this bundle was never"
note "signed, requiring --min-trust-level verified fails closed (exit non-zero):"
note "that is the correct, safe behavior — sign with 'aicr bundle --attest' to pass."
run_expect_fail "$AICR" verify "$BUNDLE" --min-trust-level verified
pause

# --- stage 3: validate (offline, --no-cluster) -------------------------------

banner "Validate — is this cluster fit for this recipe? (offline dry-run)"
if [ ! -r "$SNAPSHOT" ]; then
  note "No snapshot found at:"
  note "  $SNAPSHOT"
  note "Skipping the validate beat. To run it, capture one from a cluster with"
  note "  aicr snapshot --output snapshot.yaml"
  note "and re-run with SNAPSHOT=snapshot.yaml, or run this script from a checkout"
  note "(it defaults to the repo's offline mock snapshot)."
else
  note "--no-cluster evaluates the recipe's declarative constraints against a"
  note "snapshot with NO Kubernetes API calls. Readiness (K8s/OS/kernel) still"
  note "runs and fails CLOSED (exit 2); behavioral checks report 'skipped'."
  note "Snapshot: $SNAPSHOT"
  pause "Press Enter to validate offline"
  # A failed phase would exit non-zero; for a teaching run we don't want the
  # script to abort, so capture the exit code and report it explicitly.
  rc=0
  run "$AICR" validate --recipe "$RECIPE" --snapshot "$SNAPSHOT" --no-cluster || rc=$?
  printf '%svalidate exit code: %s%s  (0 pass/skip · 2 readiness/invalid · 5 timeout · 8 phase failed)\n' "$BOLD" "$rc" "$RESET"
fi
pause

# --- close --------------------------------------------------------------------

banner "Recap & where to go next"
note "You just ran the whole AICR model on a laptop:"
note "  recipe (criteria -> pinned config) -> inspect (asymmetric match, deploy order)"
note "  -> query (one value) -> bundle (a deployer) -> verify (trust ladder)"
note "  -> validate (offline, fail-closed readiness)."
note ""
note "Next, with a cluster and internet egress:"
note "  • Live validate + signed evidence:  demos/evidence-demo.sh"
note "  • Bundle sign + verify + tamper:    demos/bundle-attestation-demo.sh"
note "  • Consumer-side provenance verify:  demos/provenance-demo.sh"
note ""
note "Read next: demos/onboarding.md (facilitator guide),"
note "           demos/onboarding-cheatsheet.md (desk reference),"
note "           docs/user/tutorial.md, and https://validation.aicr.run"
printf '\n%sDone.%s\n' "$GREEN" "$RESET"
