# AICR Onboarding — A Self-Guided Guide

A modular path to learning **NVIDIA AI Cluster Runtime (AICR)** on your own.
Written for engineers who already run GPU-accelerated Kubernetes (drivers,
operators, node lifecycle, CI/CD) but have not yet seen AICR's approach to the
problem.

Work through the five modules in order — or read Module 1 alone for the overview.
Each module explains its concepts, points you at a hands-on exercise you can run
yourself, and links every claim to an authoritative resource in this repository
so the material stays correct as AICR evolves.

> New to the codebase? Skim [`../docs/contributor/index.md`](../docs/contributor/index.md)
> (the architecture map) and [`../docs/user/tutorial.md`](../docs/user/tutorial.md)
> (the end-to-end walkthrough) first. Everything here builds on those two pages.

## Companion Materials

Three companion artifacts live alongside this guide. Reach for them as you read.

| Artifact | File | What it's for |
|----------|------|---------------|
| **This guide** | [`onboarding.md`](onboarding.md) | The narrative you're reading — five modules, concepts, exercises, links. |
| **Slide deck** | [`onboarding-slides.html`](onboarding-slides.html) | A visual companion that skims the same arc. Self-contained HTML — open in any browser, no build step; `←/→` or `Space` to move, `F` for fullscreen. |
| **Guided script** | [`onboarding.sh`](onboarding.sh) | Runs the end-to-end path for you, one step at a time. **Laptop-only** — no cluster required (criteria-driven recipe + `--no-cluster`). |
| **Cheat sheet** | [`onboarding-cheatsheet.md`](onboarding-cheatsheet.md) | One-page desk reference: mental model, commands, "where do I look when X" table. Keep it open. |

These sit alongside the topic-specific demos already in this directory — see
[`README.md`](README.md) and [Appendix A](#appendix-a--demo-catalog--module-map)
for which existing demo reinforces which module.

## Who This Is For & What You Need

You'll get the most from this if you already know Kubernetes, Helm, GitOps (Argo
CD / Flux), GPU operators, drivers/kernels, and CI/CD. What's new is AICR's recipe
model, its validation surfaces, and its supply-chain story — that's where the
guide spends its time. It assumes you know "what a GPU Operator is" and focuses on
"what AICR does *with* it".

To follow along hands-on you need:

- The `aicr` CLI (`curl -sfL https://get.aicr.run | bash -s --`, or `brew tap NVIDIA/aicr && brew install aicr`). See [`../docs/user/installation.md`](../docs/user/installation.md).
- This repository checked out (for the recipe/overlay/mixin/CI file tours).
- `unset GITLAB_TOKEN` in any shell you run `make` in (goreleaser fails if it coexists with `GITHUB_TOKEN`).
- Optional, for the live-cluster exercises in M3/M4: a reachable cluster (Kind is fine — `make dev-env`) and, for signing, a host with public internet egress (Fulcio/Rekor are commonly VPN-blocked).

Everything else runs offline against the embedded recipe catalog — no cluster, no
credentials.

## Three Through-Lines

Three ideas recur in every module. Keep them in mind — they're what turns five
topics into one system.

1. **AICR is a design-time *generator*, not a deployment engine.** It emits the
   validated config your tools deploy (`values.yaml`, Argo CD `Application`,
   Flux `HelmRelease`, `helmfile.yaml`). It never runs `kubectl apply`, never
   reconciles, never runs as a controller. Its in-cluster footprint is
   transient: the snapshot stage runs a one-shot Job that writes a ConfigMap and
   exits, and validate deploys short-lived RBAC + one Job per check that clean up
   after themselves. (See
   [`../README.md#what-ai-cluster-runtime-is-not`](../README.md).)
2. **Four stages, one artifact each: Snapshot → Recipe → Validate → Bundle.**
   Every stage is independently invocable and produces a serializable artifact;
   inputs and outputs flow through files, stdout, or `cm://namespace/name`
   ConfigMap URIs.
3. **The boundary principle.** `pkg/cli` and `pkg/server` hold **zero** business
   logic — they parse input, format output, map exit codes. All logic lives in
   functional packages behind the `pkg/client/v1` facade, so the CLI and the
   `aicrd` server share it. When you meet a command, name the package doing
   the work (`recipe`→`pkg/recipe`, `validate`→`pkg/validator`, `bundle`→`pkg/bundler`,
   `evidence`→`pkg/evidence`). This is the single most enforced rule in review.

## How to Work Through This

The modules build on each other; read them in order. Each is self-contained:
concepts first, then a **Try It Yourself** you can run, a couple of **Questions to
Sit With**, and a short **Exercise**. Budget roughly 45–70 minutes per module if
you do the hands-on parts, and use [Check Yourself](#check-yourself) at the end to
confirm each one landed.

**Short on time?** Module 1 stands alone as a ~60-minute overview of the whole
system. Read it and run its Try-It, and you'll have the mental model — come back
for M2–M5 when you need the depth.

## Set Up Your Environment

Do this once; it takes a couple of minutes and needs no cluster:

```bash
# 1. Install the CLI
curl -sfL https://get.aicr.run | bash -s --
aicr --version

# 2. (dev shells only) avoid the goreleaser auth conflict
unset GITLAB_TOKEN

# 3. Smoke-test the offline path — resolves against the embedded catalog, no cluster
aicr recipe --service eks --accelerator h100 --os ubuntu --intent training --platform kubeflow -o /tmp/recipe.yaml
aicr query  --service eks --accelerator h100 --os ubuntu --intent training --platform kubeflow \
  --selector components.gpu-operator.values.driver.version

# 4. (optional, for the M3/M4 live-cluster exercises) a throwaway Kind cluster
make dev-env        # Kind + Tilt;  make dev-env-clean to tear down
```

If `aicr verify` or an evidence step ever reports a Sigstore trusted-root error,
run `aicr trust update` once from a host with public egress and retry.

---

# Module 1 — Why AICR & the Four-Stage Model

**Work through it in:** ~45–60 min (stands alone as the overview).
**Visuals:** [`images/overview.png`](images/overview.png) (flat-vector "Optimized · Validated · Trusted") and [`images/e2e.png`](images/e2e.png) (isometric end-to-end).
**Read alongside:** [`../README.md`](../README.md), [`../docs/contributor/index.md`](../docs/contributor/index.md).

## What You'll Be Able to Do

- State what AICR is and, just as important, [what it is **not**](../README.md).
- Sketch the four-stage pipeline and name the artifact each stage produces.
- Explain the boundary principle and why `pkg/cli`/`pkg/server` hold no logic.
- Find the right entry point in the docs tree for a given question.

## The Core Ideas

1. **The problem AICR solves.** Small differences in kernel, driver, container
   runtime, operator, and Kubernetes versions cause failures that are expensive
   to reproduce. That knowledge historically lives in private validation
   pipelines and runbooks. AICR turns the known-good combinations into a
   **reproducible, version-locked, verifiable artifact**. (See
   [`../README.md`](../README.md) "Why We Built This".)
2. **What it is not.** Not a distro, not a provisioner, not a control plane, not
   config management. It is a *configuration generator*: you bring the cluster and
   the GitOps tooling; AICR emits the config your tools deploy, and can prove it's
   correct. ([`../README.md`](../README.md) "What AICR Is Not".)
3. **The four stages.** Snapshot (capture live cluster state) → Recipe (resolve a
   version-locked config from criteria or a snapshot) → Validate (check the recipe
   against a snapshot; readiness first, then phases) → Bundle (materialize into
   Helm/Argo CD/Flux/Helmfile artifacts). Each is an independent artifact; each
   can be chained or run alone. ([`../docs/README.md`](../docs/README.md) "The Four-Stage Workflow".)
4. **The payoff.** *Same inputs → identical outputs, always*, and *one validated
   recipe re-renders for whatever pipeline you run*. Reproducibility is a hard
   rule, not a nice-to-have — it's why any output that feeds a digest/signature
   uses deterministic YAML serialization.
5. **The boundary principle and the package map.** The three-layer shape in
   [`../docs/contributor/index.md`](../docs/contributor/index.md): `cli`/`server`
   → `client/v1` facade → functional packages (`recipe`, `collector`, `validator`,
   `bundler`, `evidence`, …). Build the naming habit now — you'll use it throughout.
6. **The supported surface.** 8 services, 7 accelerators, 5 operating systems, 2
   intents, 5 platforms (see the matrix in
   [`../README.md`](../README.md#supported-environments)). That breadth is exactly
   why the recipe engine (M2) and the evidence model (M4) have to exist.

## Try It Yourself

The whole thesis is three commands, no cluster. Run the first steps of
[`onboarding.sh`](onboarding.sh) (preflight → resolve a recipe from criteria →
pull one hydrated value), or run them directly:

```bash
aicr recipe --service eks --accelerator h100 --os ubuntu --intent training --platform kubeflow -o recipe.yaml
aicr query  --service eks --accelerator h100 --os ubuntu --intent training --platform kubeflow \
  --selector components.gpu-operator.values.driver.version
```

Notice: no cluster was touched, the output is byte-stable, and the driver version
is *pinned* — this is the artifact you'd feed to Terraform/Pulumi.

## Questions to Sit With

- Where in your current release process would a "resolve the known-good config for
  this environment" step fit?
- Today, where does the "which driver/kernel/operator versions go together"
  knowledge live for your team? Who owns it?

## Exercise

Install the CLI and run the [Set Up Your Environment](#set-up-your-environment)
smoke test. You're done when you have a resolved `recipe.yaml` and a printed
driver version.

## Further Reading

- [`../docs/user/tutorial.md`](../docs/user/tutorial.md) — the linear end-to-end learning path.
- [`../docs/contributor/index.md`](../docs/contributor/index.md) — architecture, the "is / is not" tables, the package table.
- [`end-to-end-cli.md`](end-to-end-cli.md) — a runnable end-to-end CLI demo (includes the `--data` external-data flow).
- [`../ROADMAP.md`](../ROADMAP.md) · [`../GOVERNANCE.md`](../GOVERNANCE.md) · [`../ADOPTERS.md`](../ADOPTERS.md) — project context.

## Gotchas

- AICR never deploys. If you're wondering "does it roll back?" — it generates the
  artifact your GitOps tool rolls back; AICR isn't in the data path.
- AICR's in-cluster footprint is transient — a one-shot snapshot Job, plus
  short-lived validator Jobs during `validate` — never a running controller. The
  snapshot Job reads GPU state driverlessly (PCI + NFD; no `nvidia-smi`, no
  driver) and exits.

---

# Module 2 — Recipes, Overlays, Mixins → Bundles (+ the CLI)

**Work through it in:** ~55–70 min.
**Visuals:** [`images/recipe.png`](images/recipe.png) ("Asymmetric Metadata Rule Engine"), [`images/data.png`](images/data.png) ("Recipe Data Pipeline").
**Read alongside:** [`../docs/contributor/recipe.md`](../docs/contributor/recipe.md), [`../docs/user/cli-reference.md`](../docs/user/cli-reference.md), [`recipe-data-architecture.md`](recipe-data-architecture.md).

## What You'll Be Able to Do

- Explain the three-layer data model: **registry / overlay / mixin**.
- Trace a real overlay inheritance chain and predict which components resolve.
- Explain **asymmetric matching** and why it's a safety property.
- Describe the recipe→bundle handoff and the five deployer adapters.
- Know which `aicr` verbs you use daily and their key flags.

## The Core Ideas

1. **It's a compiler, not templates.** A query `{service, accelerator, os,
   intent, platform, nodes}` goes in; a resolved `RecipeResult` (merged spec +
   component refs + deployment order + validation phases) comes out; `aicr
   bundle` turns that into deployer artifacts. All the config you care about lives
   in git under `recipes/` — **no Go code for a normal chart bump.**
2. **The three layers** ([`../docs/contributor/recipe.md`](../docs/contributor/recipe.md)):
   - [`../recipes/registry.yaml`](../recipes/registry.yaml) — the component **catalog** and the *single source of truth for versions* (`defaultVersion`). A normal upgrade edits this file in exactly one place.
   - [`../recipes/overlays/`](../recipes/overlays/) (`kind: RecipeMetadata`) — criteria-matched recipe fragments with single-parent `spec.base` inheritance.
   - [`../recipes/mixins/`](../recipes/mixins/) (`kind: RecipeMixin`) — opt-in fragments carrying **only** `constraints` + `componentRefs`, shared across leaves.
   - The decision matrix: *change all recipes* → registry; *change one shape* → overlay; *share across ≥2 leaves* → mixin.
3. **A real inheritance chain.** `base → eks → eks-training → gb200-eks-training →
   gb200-eks-ubuntu-training`. Open the leaf
   [`../recipes/overlays/gb200-eks-ubuntu-training.yaml`](../recipes/overlays/gb200-eks-ubuntu-training.yaml)
   (`componentRefs: []`, pulls in the `os-ubuntu` mixin) and the intermediate
   [`../recipes/overlays/gb200-eks-training.yaml`](../recipes/overlays/gb200-eks-training.yaml)
   (where the GPU-Operator prereqs and validation blocks actually live). The
   point: **leaves declare only what differs; criteria are not inherited.** A
   mixin looks like [`../recipes/mixins/os-ubuntu.yaml`](../recipes/mixins/os-ubuntu.yaml)
   (constraints only) or [`../recipes/mixins/platform-kubeflow.yaml`](../recipes/mixins/platform-kubeflow.yaml)
   (introduces a new component).
4. **Asymmetric matching — the safety property.** Recipe-side `any` is a
   wildcard; query-side `any` is **not**. A generic query can never silently
   resolve to a hardware-specific recipe. `Specificity()` orders the merge;
   wildcard overlays like [`../recipes/overlays/gb200-any.yaml`](../recipes/overlays/gb200-any.yaml)
   apply automatically to every matching query. Source of truth:
   [`../pkg/recipe/criteria.go`](../pkg/recipe/criteria.go).
5. **The merge order, as a pipeline:** base chain → mixins → profile → registry
   defaults → CLI `--set` (later wins). Deployment order is a Kahn topological
   sort over `dependencyRefs`; cycles fail closed. Everything is ordered slices +
   deterministic serialization → same inputs, same bytes.
   ([`../pkg/recipe/metadata_store.go`](../pkg/recipe/metadata_store.go).)
6. **Recipe → Bundle handoff (the "what vs how" split).** Resolution stops at
   metadata; per-component values ([`../recipes/components/gpu-operator/`](../recipes/components/gpu-operator/))
   merge at **bundle** time. `aicr bundle -d <deployer>` serializes to `helm`
   (default), `argocd`, `argocd-helm`, `flux`, or `helmfile` — **same config,
   different pipeline** ([`../docs/user/bundling.md`](../docs/user/bundling.md)).
   Overrides: `--set` (scalar), `--set-json`/`--set-file` (lists/objects),
   `--dynamic` (defer to install-time).
7. **Three ADRs you'll meet:**
   [ADR-005 overlay refactoring](../docs/design/005-overlay-refactoring.md) (why
   mixins exist), [ADR-012 coordinate mapping](../docs/design/012-recipe-coordinate-mapping.md)
   (puts a recipe on the validation board — the tie-in to M3), and
   [ADR-015 configuration profiles](../docs/design/015-recipe-configuration-profiles.md)
   (one criteria combo, multiple GPU-stack ownership modes; live example in
   [`../recipes/overlays/aks.yaml`](../recipes/overlays/aks.yaml)).
8. **The CLI verbs you use** ([`../docs/user/cli-reference.md`](../docs/user/cli-reference.md)):
   `snapshot`, `recipe`, `query`, `validate`, `bundle`, `verify`, `evidence`,
   `diff`, `mirror`, `trust`. Plus `cm://namespace/name` ConfigMap I/O for staying
   in-cluster with no local files, and the `aicrd` REST twin (same `pkg/client/v1`
   facade). Note `aicr recipe list` shows which criteria combos have a leaf.

## Try It Yourself

Continue [`onboarding.sh`](onboarding.sh) into the bundle/inspect steps, and see
asymmetric matching for yourself:

```bash
# See exactly which overlays merged — this is the chain from The Core Ideas
aicr recipe --service eks --accelerator gb200 --intent training --os ubuntu | yq .metadata.appliedOverlays
aicr recipe --service eks | yq .metadata.appliedOverlays   # generic query: base+eks only, never a hw-specific leaf

# Recipe -> bundle, same config for a different pipeline
aicr bundle -r recipe.yaml --deployer helm    -o /tmp/bundle-helm
aicr bundle -r recipe.yaml --deployer argocd  --repo https://github.com/my-org/gitops.git -o /tmp/bundle-argocd
```

For the deep version, run [`recipe-data-architecture.md`](recipe-data-architecture.md)
end to end (inheritance, criteria matching, deployment order, `--data`).

## Questions to Sit With

- If your team added a new internal GPU SKU or a proprietary platform, where would
  it live — registry, overlay, or mixin? (Trick: a *new criteria value* is
  multi-file work; a new *component* is a registry entry.)
- The same recipe emits Helm *and* Argo CD *and* Flux. Which deployer does your
  pipeline consume, and what would you override with `--set` vs `--dynamic`?

## Exercise

1. Resolve a recipe for a different environment (`--service gke --accelerator
   h100 --os cos --intent inference --platform dynamo`) and diff its
   `appliedOverlays` and `deploymentOrder` against the EKS/training one.
2. Bundle it for two deployers and compare the folder layouts.

## Further Reading

- [`../docs/integrator/recipe-development.md`](../docs/integrator/recipe-development.md) — authoring overlays/mixins/profiles.
- [`../docs/user/component-catalog.md`](../docs/user/component-catalog.md) — every component, pin, and source.
- [`query.md`](query.md) — dot-path selectors ([ADR-004](../docs/design/004-query-command.md)).
- [`dynamic.md`](dynamic.md) — install-time values, the cluster-values split, OCI artifacts.
- [`cuj1-training.md`](cuj1-training.md) / [`cuj2-inference.md`](cuj2-inference.md) / [`cuj1-slinky-slurm.md`](cuj1-slinky-slurm.md) — full CUJ runbooks to work through.

## Gotchas

- **Version pins are single-source.** Pinning a version in an overlay/mixin fails
  CI (`TestOverlayVersionPinsMatchRegistry`) — put it in `registry.yaml`. After
  any registry/values/chart-pin change, run `make bom-docs` and commit
  [`../docs/user/container-images.md`](../docs/user/container-images.md).
- **`--set` is scalar-only.** Lists/objects need `--set-json`/`--set-file`.
- **Mixin `componentRefs` are additive-only.** Overriding a chain-declared field
  from a mixin is rejected at compose time (ADR-005 silent-override mitigation).
- **Adding a new criteria enum value is multi-file work** — start from the Go
  type in [`../pkg/recipe/criteria.go`](../pkg/recipe/criteria.go) and follow the
  audit list in [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md); grepping the new
  value returns nothing.

---

# Module 3 — Validation, UAT & the Dashboard

**Work through it in:** ~55–70 min.
**Read alongside:** [`../docs/user/validation.md`](../docs/user/validation.md), [`../docs/contributor/validator.md`](../docs/contributor/validator.md), [`../docs/contributor/uat.md`](../docs/contributor/uat.md), [`../docs/user/evidence-dashboard.md`](../docs/user/evidence-dashboard.md).
**Runbook:** [`validation-acceptance.md`](validation-acceptance.md).

## What You'll Be Able to Do

- Run `aicr validate` and read a CTRF pass/fail report and its exit code.
- Name the four phases and why performance runs **last**.
- Distinguish the **four validator surfaces** and pick the right one.
- Read [validation.aicr.run](https://validation.aicr.run) and its five consensus states.
- Triage a red UAT cell as **product** vs **infra** signal.

## The Core Ideas

1. **The question validate answers:** "is this GPU cluster fit to run this
   workload?" — reproducibly. Its two inputs are a snapshot and a recipe; its
   output is a CTRF (Common Test Report Format) pass/fail report, which then rolls
   up to the public dashboard. `aicr snapshot` + `aicr recipe` produce those two
   inputs, so a validate run naturally starts from them.
2. **The phases, in execution order.** Readiness **always** runs first — inline
   snapshot constraints (K8s version, OS, kernel), no containers — and fails
   **closed** at exit 2 before any Job deploys. Then `deployment → conformance →
   performance`, one Kubernetes Job per check. Performance runs **last by
   design**: its inference benchmark saturates every GPU and releases DRA claims
   asynchronously, which would starve conformance. Source of truth:
   [`../pkg/validator/phases.go`](../pkg/validator/phases.go).
3. **The four validator surfaces** (picking the wrong one is the #1 wasted-PR
   cause — [`../docs/contributor/validator.md`](../docs/contributor/validator.md)
   opens by saying so):
   1. **Constraint** — declarative expression in an overlay `validation:` block, evaluated against a snapshot value, no code ([`../pkg/constraints`](../pkg/constraints)).
   2. **Container check** — a Go func run as one K8s Job per check against a live cluster, listed in [`../recipes/validators/catalog.yaml`](../recipes/validators/catalog.yaml).
   3. **Component validation** — in-process Go run at `aicr bundle` time to catch misconfig before deploy.
   4. **Chainsaw health check** — read-only Chainsaw YAML in [`../recipes/checks/`](../recipes/checks/).
   Rule of thumb: *declarative snapshot assertion → constraint; active probe of a
   live cluster → check.*
4. **The chainsaw allowlist is a security posture.** The deployment validator runs
   registry-declared checks in-process under a cluster-admin ServiceAccount, so
   [`../pkg/chainsaw/allowlist.go`](../pkg/chainsaw/allowlist.go) is a **true
   allowlist** — only `assert`/`error` pass; every unknown or future op fails
   closed. (It was inverted from a denylist after a chainsaw release added a
   side-effecting `proxy` op that a denylist let through.)
5. **`--no-cluster` is CI without hardware.** Constraints (including readiness)
   still evaluate; behavioral checks report `skipped`. The **exit codes** are how
   you gate a pipeline: `0` pass/skip, `2` readiness/invalid (fail-closed even
   with `--fail-on-error=false`), `5` timeout (validator section / context
   deadline), `8` phase failed/other. In scripts, treat any non-zero as failure
   *and* check the CTRF summary.
6. **The UAT harness.** The same `aicr validate` runs nightly on **real reserved
   GPU hardware (H100 and GB200)** across a `service × GPU × intent` matrix that
   is pure **data** in
   [`../infra/uat/reservations.yaml`](../infra/uat/reservations.yaml).
   [`../.github/workflows/uat-run.yaml`](../.github/workflows/uat-run.yaml) holds
   a per-reservation concurrency lease so runs *queue* instead of racing scarce
   GPUs, then fans out to `uat-aws`/`uat-gcp`/`uat-azure`/`uat-kind`. The nightly
   cron ([`../.github/workflows/uat-nightly-batch.yaml`](../.github/workflows/uat-nightly-batch.yaml))
   runs `main + previous-N releases × intent`. Deep dive: [`../docs/contributor/uat.md`](../docs/contributor/uat.md).
7. **The dashboard: [validation.aicr.run](https://validation.aicr.run).** A public
   static site rebuilt deterministically on every merge to main. It answers "how
   many independent signed parties ran this recipe, and do they agree?" The
   load-bearing detail: it reads the **live `data/index.json` discovered from the
   GCS evidence coordinates — NOT the OSS criteria enum** — so it can surface
   out-of-enum services/accelerators that real runs produced. Navigation is
   Group (service) → Dashboard (accel+OS) → Tab (intent[-platform]) → Row
   (phase/check) → Source column (one signer). It counts distinct verified
   **signers**, never re-runs (Sybil-resistant). Reference:
   [`../docs/user/evidence-dashboard.md`](../docs/user/evidence-dashboard.md).
8. **The five consensus states** — and how not to misread them:
   **CONFIRMED** (≥2 distinct signers, all passed) · **SINGLE** (1 signer,
   uncorroborated) · **CONTESTED** (signers disagree — surfaced first-class,
   never averaged away) · **FAILING** (every signer that ran it failed) ·
   **UNTESTED** (no signer ran it — a coverage gap, **not** a pass).
9. **Triage: product vs infra signal.** A red cell is either **product** (a real
   check failed on a healthy cluster / a genuine regression) or **infra** (bringup
   terraform failure, stale TF lock, capacity exhaustion, a *superseded* run,
   arm64 QEMU-slow build). The `/aicr-uat-report` tooling classifies both and
   prints an RC priority list. Don't conflate the sibling structural surfaces:
   **Recipe Health** ([`../docs/user/recipe-health.md`](../docs/user/recipe-health.md),
   offline "does it resolve / charts pinned"), **Coverage Matrix**
   ([`../docs/user/coverage-matrix.md`](../docs/user/coverage-matrix.md), in-repo
   CUJ/verb breadth), and **TestGrid** ([`../docs/user/testgrid.md`](../docs/user/testgrid.md),
   the future live board). All four anchor on the same `CoordinateFor` mapping
   ([ADR-012](../docs/design/012-recipe-coordinate-mapping.md)).

## Try It Yourself

1. Offline validate (no cluster needed): `aicr validate -r recipe.yaml -s
   snapshot.yaml --no-cluster` — watch readiness evaluate and checks skip, then
   `echo $?` for the exit code. (The [script](onboarding.sh) does this against the
   repo's mock snapshot.)
2. Open [validation.aicr.run](https://validation.aicr.run). Navigate to a
   CONFIRMED cell and a CONTESTED/UNTESTED one; read the Source columns.
3. `curl -s https://validation.aicr.run/data/index.json | jq '.'` — confirm the
   ground truth is the live JSON, not the Go enum.

For a full phased run against a real cluster, work through [`validation-acceptance.md`](validation-acceptance.md).

## Questions to Sit With

- Which of your current release gates map to readiness constraints vs live checks?
  Which would you want as a hard gate (fail the release) vs informational?
- On the dashboard, an UNTESTED row and a green CONFIRMED row look different for a
  reason. What would you decide differently for each before a release?

## Exercise

Run `aicr validate ... --no-cluster` against the recipe from M2 and a captured or
sample snapshot. Deliberately point it at a too-old K8s constraint (edit the
snapshot) and watch the fail-closed exit 2. Then read the CTRF JSON output.

## Further Reading

- [`../docs/contributor/tests.md`](../docs/contributor/tests.md) — where each validation surface is exercised in CI.
- [`../docs/user/testgrid.md`](../docs/user/testgrid.md) — the future live board and its provenance columns.
- The `/aicr-uat-report` and `/aicr-triage` skills — tooling for UAT triage and board hygiene.

## Gotchas

- **Readiness fails closed regardless of flags.** `--fail-on-error=false`
  suppresses *phase* failures but a readiness miss still exits 2.
- **UNTESTED is not a pass**, and **CONTESTED** is never averaged away.
- **Validator image tag trap:** `:latest` is the last *stable* release, not
  `main`. On dev builds export `AICR_VALIDATOR_IMAGE_TAG=edge` or you may silently
  run older validator behavior.
- **Node-shape false-fails:** NCCL/inference floors are calibrated for full
  8-GPU H100 nodes; a smaller SKU can false-fail a healthy run.
- **Dashboard ground truth is the live `data/index.json`**, which legitimately
  hosts out-of-enum values — `curl | jq` it before claiming what coverage exists.

---

# Module 4 — Supply Chain: Provenance + Evidence

**Work through it in:** ~55–70 min.
**Visual:** [`images/trust.png`](images/trust.png) ("Recipes You Can Trust").
**Read alongside:** [`../SECURITY.md`](../SECURITY.md), [`../docs/integrator/supply-chain-verification.md`](../docs/integrator/supply-chain-verification.md), [`../docs/user/artifact-verification.md`](../docs/user/artifact-verification.md), [ADR-007](../docs/design/007-recipe-evidence.md).
**Runnable demos:** [`provenance.md`](provenance.md), [`bundle-attestation.md`](bundle-attestation.md), [`evidence.md`](evidence.md) — each with a matching `*-demo-slides.html` deck and interactive `*-demo.sh`.

## What You'll Be Able to Do

- Distinguish the **two proofs**: build provenance vs recipe evidence.
- Verify an image's SLSA provenance and know why the `--signer-workflow` pin *is* the L3 check.
- Explain `aicr bundle --attest` / `aicr verify` and the **4-level trust ladder**.
- Explain the **split-leg** evidence flow (validate on VPN / sign off VPN) and why it exists.
- State, honestly, what recipe evidence does and does not prove.

## The Core Ideas

1. **Two proofs — the whole module in one picture.**
   - **Build provenance** = *where did this come from?* NVIDIA CI signs
     images/binaries at release (SLSA, SBOM, cosign keyless). Signer = NVIDIA.
     Tools = `gh attestation verify`, `cosign`.
   - **Recipe evidence** = *what did validation actually record on real
     hardware?* A contributor with cluster access NVIDIA lacks signs an `aicr
     validate` result. Signer = the contributor. Tool = `aicr evidence verify`.
   In practice: proof #1 is what you hand downstream to prove NVIDIA built it;
   proof #2 is what lets you accept a recipe PR for hardware you can't reach
   without re-running it.
2. **Proof #1, as a consumer.** Resolve tag→digest with `crane`, then
   `gh attestation verify oci://... --signer-workflow
   NVIDIA/aicr/.github/workflows/attest-images.yaml`. Why that flag matters:
   images reach **SLSA Build L3** because a *reusable* workflow
   ([`../.github/workflows/attest-images.yaml`](../.github/workflows/attest-images.yaml))
   is the signing identity, which the build job can't forge — that isolation *is*
   L3. Binaries are L2 (signed inline in [`../.github/workflows/on-tag.yaml`](../.github/workflows/on-tag.yaml)).
   And the **SBOM** is a *different* tool (`cosign`) against a *different* subject
   (the per-platform digest, not the index).
3. **Bundle attestation — the bridge to "the bundle I'm about to deploy".**
   `aicr bundle --attest` (opt-in; bundles are unsigned by default) signs
   `checksums.txt`, which pins the whole **closed-world inventory**. `aicr verify`
   computes a **4-level trust ladder**: `verified(4) > attested(3) > unverified(2)
   > unknown(1)`. Two things to watch: use `--min-trust-level verified` (the
   default auto-detects and *passes an unsigned bundle*), and a *failed*
   attestation is a hard `unknown`, not a soft downgrade. The tamper demo in
   [`bundle-attestation.md`](bundle-attestation.md) shows this end to end.
4. **Proof #2 — and its honest boundary.** Recipe evidence
   ([ADR-007](../docs/design/007-recipe-evidence.md)) is **signer-identity-bound,
   not cluster-physicality-bound**: it proves an OIDC identity signed a
   `(recipe, snapshot, results, BOM)` tuple, not that the cluster physically
   existed. It moves the maintainer's question from "did this run?" to "do I trust
   this signer?" — and that's the whole point: it lets the project accept PRs for
   GPU hardware no NVIDIA team can reach.
5. **The split-leg flow — the operational reality.** Validation lives on the VPN
   (where the cluster is); keyless signing needs `fulcio.sigstore.dev` +
   `rekor.sigstore.dev`, which corporate VPNs routinely block. So: **Leg 1 on VPN**
   `aicr validate --emit-attestation ./out` (unsigned, content-addressed); **Leg 2
   off VPN** `aicr evidence publish ./out --push <reg>` (sign + push + pointer).
   The invariant: the bundle is content-addressed, so the digest is identical
   regardless of signing host — only the signature material differs. The community
   path signs in fork CI ([`../.github/workflows/evidence-publish.yaml`](../.github/workflows/evidence-publish.yaml)).
6. **Where cryptographic trust actually enters** (counterintuitive, worth the
   time): the merge-time pointer-contract gate
   ([`../.github/workflows/evidence-pointer-contract.yaml`](../.github/workflows/evidence-pointer-contract.yaml))
   is **structural** — it checks the *claimed* signer's slug + allowlist, no
   signature check. Real verification happens **after merge at ingest**
   ([`../.github/workflows/evidence-ingest.yaml`](../.github/workflows/evidence-ingest.yaml)),
   which verifies the signature before any result is counted. A lying pointer
   passes the gate but fails ingest. The trust root is
   [`../recipes/evidence/allowlist.yaml`](../recipes/evidence/allowlist.yaml).
7. **Private / enterprise signing is the same two commands, different trust
   material** ([`private-signing.md`](private-signing.md)): self-hosted
   Fulcio/Rekor + `verify --trust-root` (additive — unioned with the public root),
   KMS + `verify --key`, or air-gapped `--tlog-upload=false` + `--insecure-ignore-tlog`.
   The anchor that never goes private: `aicr bundle --attest` still verifies the
   CLI binary's *own* NVIDIA-CI attestation against public Sigstore first, so you
   always need a release-archive binary.
8. **The producer side, easy to forget.** Verification proves an artifact *you
   hold* is legit; it can't tell you someone signed something *as* you. Keyless
   leaves no local trace, so the Rekor transparency log is the only detector. AICR
   signs to **Rekor v2** ([`../docs/contributor/rekor-v2-signing.md`](../docs/contributor/rekor-v2-signing.md))
   specifically to make identity monitoring feasible, and runs
   [`../.github/workflows/rekor-monitor.yaml`](../.github/workflows/rekor-monitor.yaml)
   against its own release identity.

## Try It Yourself

Each of the three supply-chain demos has a self-contained slide deck and an
interactive script — pick whichever fits:

- **Bundle attestation** (no cluster): [`bundle-attestation-demo.sh`](bundle-attestation-demo.sh)
  — sign a bundle, `aicr verify`, then tamper and watch it fail. Deck:
  [`bundle-attestation-demo-slides.html`](bundle-attestation-demo-slides.html).
- **Build provenance** (consumer side, needs internet): [`provenance-demo.sh`](provenance-demo.sh).
  Deck: [`provenance-demo-slides.html`](provenance-demo-slides.html).
- **Recipe evidence** (split-leg): [`evidence-demo.sh`](evidence-demo.sh). Deck:
  [`evidence-demo-slides.html`](evidence-demo-slides.html).

## Questions to Sit With

- Which proof does your downstream consumer actually need — provenance, evidence,
  or both — and where in your pipeline would you gate on `--min-trust-level verified`?
- Recipe evidence trades "did the cluster exist" for "do I trust the signer." Is
  that the right trade for your team's threat model? What would close the gap?

## Exercise

Run [`bundle-attestation-demo.sh`](bundle-attestation-demo.sh) locally
(laptop-only): produce a signed bundle, verify it at `verified`, edit one byte,
and watch `aicr verify` drop to `unknown` and exit non-zero.

## Further Reading

- [`../docs/contributor/evidence-ingest.md`](../docs/contributor/evidence-ingest.md) · [`../docs/contributor/evidence-publishing.md`](../docs/contributor/evidence-publishing.md) · [`../docs/contributor/evidence-dashboard-publish.md`](../docs/contributor/evidence-dashboard-publish.md).
- [`../pkg/evidence/verifier`](../pkg/evidence/verifier) — the verifier internals.

## Gotchas

- Default `aicr verify` (`--min-trust-level max`) **passes an unsigned bundle** —
  always pass `verified` explicitly in a deploy gate.
- Keyless signing hits Fulcio/Rekor; corporate VPNs block them at the IP level —
  split the legs or sign from a host with public egress.
- `aicr bundle --attest` refuses to sign if the CLI binary isn't itself attested —
  a local `go build` won't do; use a release-archive binary.
- SBOM lives on the per-platform digest; provenance/OpenVEX on the index digest.
- Cosign floors: v3.0.1+ to *verify* a Rekor v2 bundle, v3.1.0+ to *sign* one.

---

# Module 5 — Dev Practices, CI & Release

**Work through it in:** ~45–60 min.
**Read alongside:** [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md), [`../CONTRIBUTING.md`](../CONTRIBUTING.md), [`../DEVELOPMENT.md`](../DEVELOPMENT.md), [`../RELEASING.md`](../RELEASING.md), [`../docs/contributor/maintaining.md`](../docs/contributor/maintaining.md).

## What You'll Be Able to Do

- Run `make qualify` and know exactly what it gates and how failures map back.
- Explain the coverage gate (80% floor, `validators/` excluded).
- Map the CI topology: what gates a PR vs what runs on tag.
- Follow the PR/branch hygiene rules (sign `-S -s`, rebase+squash, labels).
- Describe the release runbook end to end.

## The Core Ideas

1. **Local dev equals CI.** [`../.settings.yaml`](../.settings.yaml) + `.go-version`
   are the single source of truth for every tool pin and threshold, and
   **`make qualify` reproduces CI locally**. If qualify is green, the PR
   merge-gate is green.
2. **`make qualify`, end to end** ([`../Makefile`](../Makefile)): `test-coverage →
   lint → tuning-check → e2e → scan → license-check`. When CI is red, the failing
   job name maps 1:1 to one of these sub-targets — so you know exactly which local
   command to rerun.
3. **The coverage gate.** An 80% floor from `.settings.yaml`
   (`quality.coverage_threshold`), enforced by `make test-coverage`. The
   `validators/` packages are *deliberately excluded* from the profile (they run
   lower and would drag the project number under the floor). Adding an uncovered
   exported func is the classic way to turn CI red.
4. **The CI topology** ([`../.github/workflows/`](../.github/workflows/)):
   - [`qualification.yaml`](../.github/workflows/qualification.yaml) — the reusable engine (test / lint / cli-e2e / e2e / security-scan).
   - [`merge-gate.yaml`](../.github/workflows/merge-gate.yaml) — **the PR gate**; classifies the diff, runs the suite (+ CodeQL, malware-scan, actionlint, license/renovate/bom/tuning/notices freshness), and funnels into a fail-closed `gate` job.
   - [`on-push.yaml`](../.github/workflows/on-push.yaml) — runs on main, publishes validator `:edge` + `sha-<commit>` images.
   - [`on-tag.yaml`](../.github/workflows/on-tag.yaml) — the release pipeline.
5. **The `GITLAB_TOKEN` gotcha.** Any goreleaser-wrapping target (`build`,
   `qualify`, `e2e`, release) fails if `GITLAB_TOKEN` and `GITHUB_TOKEN` are both
   set. `unset GITLAB_TOKEN` first. Laptop-only; CI is clean.
6. **PR & branch hygiene** ([`../CONTRIBUTING.md`](../CONTRIBUTING.md)): every
   commit is `git commit -s -S` (`-s` DCO sign-off, `-S` cryptographic signature)
   — a branch ruleset *rejects unsigned pushes before review*. Rebase onto
   `origin/main` and squash to one commit. Add a `theme/*` label (`area/*` auto-
   assign); don't add `P0–P2` or `size/*` to PRs. Fill the canonical PR template;
   keep the title < 70 chars.
7. **The release runbook** ([`../RELEASING.md`](../RELEASING.md),
   [`../docs/contributor/maintaining.md`](../docs/contributor/maintaining.md)):
   `make qualify` on main → `make bump-patch`/`bump-minor` (tags HEAD and pushes
   the tag — **no commit**, the tag points at code) → `on-tag.yaml` builds
   candidate images → per-arch vuln scan + **SLSA L3 attest** → promote
   `version` + `:latest` aliases → publish the GitHub release → Cloud Run demo +
   Homebrew. Important releases: `make bump-rc` then `make bump-promote` re-tags
   the *same* SHA. Recovery is always "Re-run failed jobs" (idempotent), never
   manual alias repointing.
8. **Two docs-hygiene gates you'll trip.** `.claude/CLAUDE.md` is canonical for
   agent rules and `AGENTS.md` must stay a synced mirror (`check-agents-sync`
   inside `make lint`). And any registry/values/chart-pin change needs
   `make bom-docs` committed — with the caveat that *rendered-image drift* is only
   caught by the opt-in `make bom-check` or the weekly
   [`bom-refresh.yaml`](../.github/workflows/bom-refresh.yaml).

## Try It Yourself

```bash
unset GITLAB_TOKEN
make test          # race-enabled unit tests + coverage number
make lint          # golangci-lint (verify your version matches the .settings.yaml pin)
# then the whole gate (grab coffee):
make qualify
```

Or, hardware-free end-to-end: `make kwok-e2e RECIPE=eks-training` renders and
deploys a recipe against a simulated cluster with no GPUs.

## Questions to Sit With

- Which of your current pre-merge checks does `make qualify` already cover, and
  which are unique to your pipeline?
- The release is "everything on main since the last tag" (no cherry-pick). How
  does that compare to your current release-branch model?

## Exercise

Clone, `unset GITLAB_TOKEN`, run `make test` and `golangci-lint run -c
.golangci.yaml ./pkg/recipe/...`. Then read the `gate` job in
[`merge-gate.yaml`](../.github/workflows/merge-gate.yaml) and trace how a
docs-only PR still goes green (the `*-skip` twin jobs).

## Further Reading

- [`../docs/contributor/tests.md`](../docs/contributor/tests.md) — the test taxonomy (unit / chainsaw / KWOK / e2e / UAT).
- [`../docs/contributor/index.md`](../docs/contributor/index.md) — the decision matrix for where new code goes.
- [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md) — the coding rules and the anti-patterns table (read the whole thing once).

## Gotchas

- `make lint` runs the **bare** `golangci-lint` from PATH — a Homebrew-drifted
  version silently misses/over-flags. Check `golangci-lint version` against the
  `.settings.yaml` pin; `make tools-check` shows a ⚠.
- The `gate` job is fail-closed: if `check-paths` errors, downstream jobs *skip*
  (not fail) — the gate explicitly fails when `check-paths` didn't succeed.
- A "documentation only" label does **not** exempt `.go` changes from the lint gate.
- Never amend a published tag; if a tag didn't trigger `on-tag.yaml`, delete the
  local tag and re-push from a fresh shell.

---

# Check Yourself

Quick questions to test your own understanding (answers are in the linked docs):

- **M1:** Name the four stages and the artifact each produces. What is AICR *not*?
- **M2:** A generic `--service eks` query — does it resolve a GB200-specific
  recipe? Why not? Where does a component's version pin live?
- **M3:** Which validate phase runs last, and why? What does an **UNTESTED**
  dashboard cell mean? What exit code is a readiness failure?
- **M4:** Name the two proofs and their signers. Why are images SLSA L3 but
  binaries L2? What does recipe evidence *not* prove?
- **M5:** What does `make qualify` run, in order? Why must commits be `-S`-signed?
  What triggers `on-tag.yaml`?

# Appendix A — Demo Catalog → Module Map

Existing demos in this directory, mapped to the module they reinforce. See
[`README.md`](README.md) for one-line descriptions.

| Module | Runbooks (`.md`) | Interactive (`.sh`) | Decks (`.html`) | Visuals |
|--------|------------------|---------------------|-----------------|---------|
| M1 | [`end-to-end-cli.md`](end-to-end-cli.md) | [`onboarding.sh`](onboarding.sh) | [`onboarding-slides.html`](onboarding-slides.html) | [`images/overview.png`](images/overview.png), [`images/e2e.png`](images/e2e.png) |
| M2 | [`recipe-data-architecture.md`](recipe-data-architecture.md), [`query.md`](query.md), [`dynamic.md`](dynamic.md), [`cuj1-training.md`](cuj1-training.md), [`cuj2-inference.md`](cuj2-inference.md), [`cuj1-slinky-slurm.md`](cuj1-slinky-slurm.md) | — | [`slinky-slurm-demo.html`](slinky-slurm-demo.html) | [`images/recipe.png`](images/recipe.png), [`images/data.png`](images/data.png) |
| M3 | [`validation-acceptance.md`](validation-acceptance.md), [`cuj2-demo.md`](cuj2-demo.md) | — | — | — |
| M4 | [`provenance.md`](provenance.md), [`bundle-attestation.md`](bundle-attestation.md), [`evidence.md`](evidence.md), [`private-signing.md`](private-signing.md) | [`provenance-demo.sh`](provenance-demo.sh), [`bundle-attestation-demo.sh`](bundle-attestation-demo.sh), [`evidence-demo.sh`](evidence-demo.sh) | [`provenance-demo-slides.html`](provenance-demo-slides.html), [`bundle-attestation-demo-slides.html`](bundle-attestation-demo-slides.html), [`evidence-demo-slides.html`](evidence-demo-slides.html) | [`images/trust.png`](images/trust.png) |
| M5 | [`../docs/contributor/maintaining.md`](../docs/contributor/maintaining.md), [`../docs/contributor/tests.md`](../docs/contributor/tests.md) | — | — | — |

> Note: [`slinky-slurm-demo.html`](slinky-slurm-demo.html) and the
> [`images/`](images/) infographic prompts exist on disk but are not listed in the
> demos `README.md` table — they're there even though the table omits them.

# Appendix B — Glossary & Canonical Sources

The [`../docs/README.md`](../docs/README.md) glossary is the canonical term list
(Snapshot, Recipe, Criteria, Overlay, Mixin, Bundle, Bundler, Deployer, Component,
ComponentRef, Constraint, Validation Phase, Measurement, Specificity, Asymmetric
matching, ConfigMap URI, SLSA/SBOM). Single sources of truth for when you need the
real value of X:

| Question | Source of truth |
|----------|-----------------|
| Supported services/accelerators/OS/intents/platforms | [`../README.md`](../README.md#supported-environments) + `api/aicr/v1/server.yaml` enums |
| The component set and pinned versions | [`../recipes/registry.yaml`](../recipes/registry.yaml) → [`../docs/user/component-catalog.md`](../docs/user/component-catalog.md) |
| Which recipes resolve and are structurally healthy | [`../docs/user/recipe-health.md`](../docs/user/recipe-health.md) |
| Live validation coverage & consensus | [validation.aicr.run](https://validation.aicr.run) (`data/index.json`) |
| Tool versions & quality thresholds | [`../.settings.yaml`](../.settings.yaml) |
| Every CLI command and flag | [`../docs/user/cli-reference.md`](../docs/user/cli-reference.md) |
| Coding rules & anti-patterns | [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md) |
