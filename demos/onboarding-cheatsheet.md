# AICR Cheat Sheet

One-page desk reference for AICR. Companion to the
[onboarding facilitator guide](onboarding.md) and [slide deck](onboarding-slides.html).
Every claim links to its source of truth.

## The Mental Model (say it in one breath)

AICR is a **design-time configuration generator**, not a deployment engine. You
bring the GPU-Kubernetes cluster and your GitOps tooling; AICR emits the
validated, version-locked config your tools deploy — and can prove it's correct.
It never runs `kubectl apply` on your recipe. Its in-cluster footprint is
transient: a one-shot snapshot Job, plus short-lived validator Jobs (RBAC + pods)
during the deployment/conformance/performance phases. ([`../README.md`](../README.md))

```
┌──────────┐    ┌────────┐    ┌──────────┐    ┌────────┐
│ Snapshot │──▶ │ Recipe │──▶ │ Validate │──▶ │ Bundle │
└──────────┘    └────────┘    └──────────┘    └────────┘
 capture cluster  resolve       check          emit Helm / Argo CD /
 state (a Job)    version-lock  constraints    Flux / Helmfile artifacts
                  config        + phases
```

**Boundary principle:** `pkg/cli` + `pkg/server` hold **zero** logic; everything
real lives in functional packages behind the `pkg/client/v1` facade. When you see
a verb, name the package: `recipe`→`pkg/recipe`, `validate`→`pkg/validator`,
`bundle`→`pkg/bundler`, `evidence`→`pkg/evidence`. ([`../docs/contributor/index.md`](../docs/contributor/index.md))

## The Five Verbs (daily driver)

```bash
# 1. SNAPSHOT — capture live cluster state (driverless: PCI + NFD, no nvidia-smi)
aicr snapshot --output snapshot.yaml
aicr snapshot --namespace gpu-operator --output cm://gpu-operator/aicr-snapshot   # to a ConfigMap

# 2. RECIPE — resolve a version-locked config (from criteria, or from a snapshot)
aicr recipe --service eks --accelerator h100 --os ubuntu --intent training --platform kubeflow -o recipe.yaml
aicr recipe --snapshot snapshot.yaml --intent training -o recipe.yaml
aicr recipe list --service eks --intent training           # which criteria combos have a leaf overlay

# 3. QUERY — pull one hydrated value (great for IaC vars)
aicr query --service eks --accelerator h100 --os ubuntu --intent training \
  --selector components.gpu-operator.values.driver.version

# 4. BUNDLE — materialize for a deployer (same config, different pipeline)
aicr bundle -r recipe.yaml --deployer helm -o ./bundles                 # helm | argocd | argocd-helm | flux | helmfile
aicr bundle -r recipe.yaml --deployer argocd --repo https://github.com/org/gitops.git -o ./bundles
aicr bundle -r recipe.yaml --set gpuoperator:driver.version=570.86.16 -o ./bundles

# 5. VALIDATE — is this cluster fit for this recipe?
aicr validate -r recipe.yaml -s snapshot.yaml                          # readiness -> deployment -> conformance -> performance
aicr validate -r recipe.yaml -s snapshot.yaml --no-cluster             # CI without hardware (constraints only)
```

Supporting verbs: `aicr diff` (drift), `aicr verify` (bundle trust), `aicr
evidence` (validity attestations), `aicr mirror` (air-gap), `aicr trust update`
(refresh Sigstore root). Full reference: [`../docs/user/cli-reference.md`](../docs/user/cli-reference.md).

## Criteria (the query dimensions)

`service · accelerator · os · intent · platform · nodes` — the 6 fields that
select a recipe. Supported values ([`../README.md`](../README.md#supported-environments)):

| Dimension | Values |
|-----------|--------|
| Services | AKS · BCM · EKS · GKE · Kind · LKE · OCP · OKE |
| Accelerators | A100 · B200 · GB200 · H100 · H200 · L40 · RTX PRO 6000 |
| Operating systems | Amazon Linux · COS · RHEL · Talos · Ubuntu |
| Workload intents | Inference · Training |
| Platforms | Dynamo · Kubeflow · NIM · Run:ai · Slurm (Slinky) |

**Asymmetric matching:** recipe-side `any` is a wildcard; query-side `any` is
**not**. A generic query never silently resolves to a hardware-specific recipe.
([`../pkg/recipe/criteria.go`](../pkg/recipe/criteria.go))

## Recipe Data Model (all in git, no Go for a chart bump)

| Layer | Path | Role |
|-------|------|------|
| **Registry** | [`../recipes/registry.yaml`](../recipes/registry.yaml) | Component catalog + **single source of truth for versions** (`defaultVersion`) |
| **Overlays** | [`../recipes/overlays/`](../recipes/overlays/) | Criteria-matched recipes; single-parent `spec.base` inheritance |
| **Mixins** | [`../recipes/mixins/`](../recipes/mixins/) | Opt-in fragments: `constraints` + `componentRefs` only (additive) |
| **Component values** | [`../recipes/components/`](../recipes/components/) | Per-component `values.yaml`, merged at **bundle** time |

Decision matrix: *change all recipes* → registry · *change one shape* → overlay ·
*share across ≥2 leaves* → mixin. Merge order: `base chain → mixins → profile →
registry defaults → CLI --set` (later wins). Deployment order = topological sort
over `dependencyRefs`. ([`../docs/contributor/recipe.md`](../docs/contributor/recipe.md))

## Validate: Phases, Exit Codes, Trust

**Phases** (fixed order): **readiness** (always first, inline constraints, no
containers, fails closed) → **deployment** → **conformance** → **performance**
(last — its benchmark saturates GPUs). ([`../pkg/validator/phases.go`](../pkg/validator/phases.go))

**Exit codes** (gate on these): `0` pass/skip · `2` readiness / invalid
(fail-closed even with `--fail-on-error=false`) · `5` timeout (validator section /
context deadline) · `8` phase check failed. Treat any non-zero as failure **and** check the CTRF summary.

**Four validator surfaces** ([`../docs/contributor/validator.md`](../docs/contributor/validator.md)) —
picking the wrong one is the #1 wasted PR: (1) declarative **constraint**
(snapshot value, no code) · (2) container **check** (a K8s Job,
[`../recipes/validators/catalog.yaml`](../recipes/validators/catalog.yaml)) · (3)
bundle-time **component validation** · (4) **chainsaw health check**
([`../recipes/checks/`](../recipes/checks/), read-only allowlist).

## The Dashboard — [validation.aicr.run](https://validation.aicr.run)

Public site rebuilt deterministically on every merge. **Ground truth is the live
`data/index.json` discovered from GCS evidence coordinates — NOT the OSS enum**
(so it hosts out-of-enum values; `curl | jq` it before claiming coverage). Counts
distinct verified **signers**, never re-runs. Nav: Group → Dashboard → Tab → Row →
Source. ([`../docs/user/evidence-dashboard.md`](../docs/user/evidence-dashboard.md))

**Five consensus states:** `CONFIRMED` (≥2 signers, all pass) · `SINGLE` (1
signer) · `CONTESTED` (signers disagree — never averaged away) · `FAILING` (all
failed) · `UNTESTED` (**coverage gap, not a pass**).

**UAT triage:** a red cell is **product** signal (real check failed on a healthy
cluster / regression) or **infra** signal (bringup TF failure, stale lock,
capacity, superseded run, arm64-slow build). Use `/aicr-uat-report`.

## Supply Chain — Two Proofs

| | Build provenance | Recipe evidence |
|---|---|---|
| **Question** | Where did it come from? | What did validation record? |
| **Signer** | NVIDIA CI | A contributor with cluster access we lack |
| **Artifact** | images / binaries | a signed `aicr validate` result |
| **Tool** | `gh attestation verify`, `cosign` | `aicr evidence verify` |
| **Level** | images **SLSA L3**, binaries L2 | signer-bound, *not* cluster-physicality-bound |

**Trust ladder** (`aicr verify`): `verified(4) > attested(3) > unverified(2) >
unknown(1)`. Gate deploys with `--min-trust-level verified` (the default passes an
unsigned bundle!). A *failed* attestation is a hard `unknown`, not a downgrade.

```bash
# Verify an image (the --signer-workflow pin IS the SLSA L3 check)
gh attestation verify oci://ghcr.io/nvidia/aicr@$DIGEST --repo NVIDIA/aicr \
  --signer-workflow NVIDIA/aicr/.github/workflows/attest-images.yaml --source-ref refs/tags/$TAG

# Sign + gate a bundle
aicr bundle -r recipe.yaml --attest -o ./bundles
aicr verify ./bundles --min-trust-level verified

# Split-leg evidence: validate on VPN (unsigned), sign off VPN
aicr validate -r recipe.yaml -s snapshot.yaml --emit-attestation ./out   # Leg 1 (VPN)
aicr evidence publish ./out --push ghcr.io/<owner>/aicr-evidence          # Leg 2 (off VPN)
aicr evidence verify recipes/evidence/<recipe>/<src>/<digest>.yaml
```

Docs: [`../SECURITY.md`](../SECURITY.md) · [`../docs/integrator/supply-chain-verification.md`](../docs/integrator/supply-chain-verification.md) · [ADR-007](../docs/design/007-recipe-evidence.md).

## Dev / CI / Release

```bash
unset GITLAB_TOKEN        # ALWAYS first in a make shell (goreleaser + GITHUB_TOKEN conflict)
make qualify             # = test-coverage -> lint -> tuning-check -> e2e -> scan -> license-check  (== CI)
make test                # race unit tests + coverage profile (no floor)
make test-coverage       # enforces the 80% floor (validators/ excluded)
golangci-lint run -c .golangci.yaml ./pkg/recipe/...   # per changed pkg, before push
make kwok-e2e RECIPE=eks-training                       # hardware-free end-to-end
make bom-docs            # after ANY registry/values/chart-pin change; commit docs/user/container-images.md
git commit -s -S -m "…"  # -s DCO sign-off + -S crypto signature (unsigned pushes are rejected)
```

**CI topology:** [`qualification.yaml`](../.github/workflows/qualification.yaml)
(reusable engine) · [`merge-gate.yaml`](../.github/workflows/merge-gate.yaml)
(**the PR gate**, fail-closed `gate` job) · [`on-push.yaml`](../.github/workflows/on-push.yaml)
(main → `:edge` images) · [`on-tag.yaml`](../.github/workflows/on-tag.yaml)
(release). **Release:** `make qualify` → `make bump-patch`/`bump-minor` (tags HEAD,
no commit) → `on-tag.yaml`. RC: `make bump-rc` → `make bump-promote TAG=…`
(re-tags the same SHA). ([`../RELEASING.md`](../RELEASING.md))

## Where Do I Look When… ?

| Symptom | Look here |
|---------|-----------|
| Recipe won't resolve / ignores a stated dimension | Coverage post-condition — [`../pkg/recipe/coverage.go`](../pkg/recipe/coverage.go); every stated dimension must be honored |
| Unexpected components in a recipe | *All* matching overlays (incl. `intent:any` wildcards), not just the base — [`../recipes/overlays/`](../recipes/overlays/) |
| `--set` produced invalid YAML | `--set` is scalar-only; use `--set-json`/`--set-file` for lists/objects |
| `validate` exits 2 under `--no-cluster` | A readiness constraint failed (K8s/OS/kernel) — it's not a check failure |
| Bundle verifies as `unknown` | A present attestation *failed*, or the closed-world inventory is incomplete/invalid (legacy bundle) — regenerate/re-sign. (Absent attestation → `unverified`; external `--data` → `attested`) |
| Signing hangs / TLS-resets on VPN | Fulcio/Rekor blocked — split the legs or sign off VPN |
| CI red but every visible job green | `check-paths` in [`merge-gate.yaml`](../.github/workflows/merge-gate.yaml) — the `gate` fails closed |
| `make build`/`qualify` auth conflict | `unset GITLAB_TOKEN` |
| Validator behaves like an old release | `:latest` = last stable; set `AICR_VALIDATOR_IMAGE_TAG=edge` on dev builds |
| A recipe missing from the dashboard | Its `service`/`accelerator`/`intent` went `any` → not coordinatable ([ADR-012](../docs/design/012-recipe-coordinate-mapping.md)) |
| Dashboard coverage vs the enum disagree | The dashboard's live `data/index.json` is ground truth, not the Go enum |

## Key Links

- **Docs:** [docs.nvidia.com/aicr](https://docs.nvidia.com/aicr) · [`../docs/README.md`](../docs/README.md) (glossary + doc map)
- **Tutorial:** [`../docs/user/tutorial.md`](../docs/user/tutorial.md) · **CLI:** [`../docs/user/cli-reference.md`](../docs/user/cli-reference.md)
- **Architecture:** [`../docs/contributor/index.md`](../docs/contributor/index.md) · **Coding rules:** [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md)
- **Dashboard:** [validation.aicr.run](https://validation.aicr.run) · **Repo:** [github.com/NVIDIA/aicr](https://github.com/NVIDIA/aicr)
- **Slack:** [#aicr](https://kubernetes.slack.com/archives/C0AQMPP1BK7) on Kubernetes Slack
