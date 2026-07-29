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

# Unit harness for the pure helpers in lib/phases.sh — the k8s version
# comparison that phase_compat's reuse/skip verdict rests on. These are pure
# string functions with no cluster dependency, so they are unit-testable even
# though the phases around them are not.
#
# A regression here is invisible until a live UAT night: a false NEGATIVE
# hard-fails an otherwise-good cell (exit COMPAT_EXIT_INCOMPATIBLE), and a false
# POSITIVE reuses a cluster whose k8s version the recipe forbids, making that
# cell's validate result meaningless.
#
# Run directly: bash tests/uat/lib/phases_test.sh
# Wired into CI by the merge gate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourcing phases.sh only assigns defaults and defines functions (no side
# effects). Resolve the subject SCRIPT_DIR-relative — never a deployed copy.
# shellcheck source=phases.sh
source "${SCRIPT_DIR}/phases.sh"

fails=0
check() { # <name> <want_rc> <got_rc>
    local name="$1" want_rc="$2" got_rc="$3"
    if [[ "${got_rc}" == "${want_rc}" ]]; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name} (want rc=${want_rc}; got rc=${got_rc})"
        fails=$((fails + 1))
    fi
}
check_out() { # <name> <want_stdout> <got_stdout>
    local name="$1" want="$2" got="$3"
    if [[ "${got}" == "${want}" ]]; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name} (want '${want}'; got '${got}')"
        fails=$((fails + 1))
    fi
}
sat() { # <ver> <constraint> -> rc
    k8s_version_satisfies "$1" "$2"
    echo $?
}

echo "--- k8s_version_normalize ---"
check_out "strips v prefix and pads to X.Y.Z"      "1.35.0" "$(k8s_version_normalize v1.35)"
check_out "drops EKS build suffix"                 "1.35.0" "$(k8s_version_normalize v1.35.0-eks-abc123)"
check_out "drops GKE suffix"                       "1.33.4" "$(k8s_version_normalize 1.33.4-gke.100)"
check_out "drops +build metadata"                  "1.32.4" "$(k8s_version_normalize 1.32.4+build.7)"
check_out "pads major-only"                        "1.0.0"  "$(k8s_version_normalize 1)"

echo "--- k8s_version_cmp ---"
check_out "greater"            "1"  "$(k8s_version_cmp 1.35.0 1.32.4)"
check_out "less"               "-1" "$(k8s_version_cmp 1.32.4 1.35.0)"
check_out "equal after norm"   "0"  "$(k8s_version_cmp v1.35.0-eks 1.35)"
# Numeric (not lexical) ordering: 1.9 < 1.10 despite '9' > '1' as a string.
check_out "numeric not lexical" "-1" "$(k8s_version_cmp 1.9.0 1.10.0)"

echo "--- k8s_version_satisfies: the operators recipes actually use ---"
# Every committed K8s.server.version value today is a plain '>= X.Y[.Z]'.
check "real EKS gitVersion vs >= 1.32"   0 "$(sat 'v1.35.0-eks-abc123' '>= 1.32')"
check "real GKE gitVersion vs >= 1.32"   0 "$(sat 'v1.33.4-gke.100'    '>= 1.32')"
check "below the floor is unsatisfied"   1 "$(sat '1.31.0'             '>= 1.32')"
check "patch-level floor satisfied"      0 "$(sat '1.32.5'             '>= 1.32.4')"
check "patch-level floor unsatisfied"    1 "$(sat '1.32.0'             '>= 1.32.4')"

echo "--- k8s_version_satisfies: full operator set (parity with pkg/constraints) ---"
check "gt satisfied"        0 "$(sat 1.35.0 '> 1.34')"
check "gt unsatisfied"      1 "$(sat 1.34.0 '> 1.34')"
check "lt satisfied"        0 "$(sat 1.33.2 '< 1.34')"
check "lt unsatisfied"      1 "$(sat 1.35.0 '< 1.34')"
check "lte boundary"        0 "$(sat 1.35.0 '<= 1.35')"
check "lte beyond"          1 "$(sat 1.35.7 '<= 1.35')"
check "eq bare"             0 "$(sat 1.35.0 '1.35')"
check "eq explicit =="      0 "$(sat 1.35.0 '== 1.35.0')"
check "eq mismatch"         1 "$(sat 1.35.0 '1.34')"
# != has no branch in the pre-fix parser and fell through to fail-closed, which
# hard-failed a cell the Go evaluator would have accepted.
check "ne satisfied"        0 "$(sat 1.33.0 '!= 1.34')"
check "ne unsatisfied"      1 "$(sat 1.34.0 '!= 1.34')"

echo "--- k8s_version_satisfies: compound ranges are AND, not fail-closed ---"
check "compound both clauses hold"   0 "$(sat 1.35.0 '>= 1.32, < 1.36')"
check "compound upper violated"      1 "$(sat 1.36.0 '>= 1.32, < 1.36')"
check "compound lower violated"      1 "$(sat 1.31.0 '>= 1.32, < 1.36')"
check "compound three clauses"       0 "$(sat 1.34.0 '>= 1.32, < 1.36, != 1.33')"

echo "--- k8s_version_satisfies: fail closed on anything unevaluable ---"
check "tilde range unsupported"   1 "$(sat 1.35.0 '~1.35')"
check "caret range unsupported"   1 "$(sat 1.35.0 '^1.34')"
check "x-range unsupported"       1 "$(sat 1.35.0 '1.x')"
check "empty constraint"          1 "$(sat 1.35.0 '')"
check "whitespace-only constraint" 1 "$(sat 1.35.0 '   ')"
check "garbage constraint"        1 "$(sat 1.35.0 'not-a-version')"
check "partially-valid compound"  1 "$(sat 1.35.0 '>= 1.32, ~1.36')"

echo "--- ns_is_protected: the uninstall sweep must never delete these ---"
for ns in default kube-system kube-public kube-node-lease kube-flannel \
          gke-managed-system gmp-system calico-system tigera-operator azure-arc aks-command; do
    ns_is_protected "${ns}"; check "protected: ${ns}" 0 "$?"
done
for ns in gpu-operator kubeflow dynamo-system aicr-validation nvidia-system monitoring; do
    ns_is_protected "${ns}"; check "deletable: ${ns}" 1 "$?"
done

echo
if (( fails > 0 )); then
    echo "${fails} test(s) FAILED"
    exit 1
fi
echo "all tests passed"
