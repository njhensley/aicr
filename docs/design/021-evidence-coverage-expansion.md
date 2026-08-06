# ADR-021: Scaling Recipe Validation Evidence Coverage

## Status

**Proposed** — 2026-08-04.

Originated from the coverage gap on the public evidence dashboard
([validation.aicr.run](https://validation.aicr.run)): the dashboard carries
signed evidence for only a small fraction of AICR's supported recipe surface,
and almost all of it is single-source. This ADR records the decisions that make
broad coverage achievable — chiefly letting the released `aicr` binary publish
evidence directly, and feeding coverage from internal qualification pipelines
rather than dedicated UAT capacity alone.

Builds on the evidence pipeline in [ADR-007](007-recipe-evidence.md) (verifiable
recipe test evidence), the coordinate mapping in
[ADR-012](012-recipe-coordinate-mapping.md), and the recipe-health leaf
enumeration in [ADR-009](009-recipe-health-tracking.md).

## Problem

AICR's value is *validated* GPU-cluster configurations — recipes whose
correctness is demonstrated, not asserted. The evidence dashboard is where that
demonstration becomes public and verifiable, and today it falls far short of the
supported surface. Two metrics, against the current open-source leaf catalog of
**44 recipe leaves** (`docs/user/recipe-health.md`; the leaf-driven enumeration
[ADR-009](009-recipe-health-tracking.md) defines; dashboard figures as of
2026-08-04):

- **Breadth** — recipes with at least one signed, allowlisted source: ~14 of 44
  (~32%).
- **Depth** — recipes corroborated by two or more independent signers: 2 of 44
  (~4.5%).

Two structural causes:

1. **No publish path outside AICR CI.** The released `aicr` binary can *emit* and
   *sign* evidence (`aicr validate --emit-attestation --push`) but cannot write
   to the evidence bucket. The GCS write is performed only by AICR's own CI, so
   any producer that is not an AICR UAT lane depends on AICR CI to publish on its
   behalf.
2. **Coverage rides on dedicated UAT capacity.** First-party evidence comes from
   nightly UAT lanes bound to reserved GPU capacity. Standing up a lane per SKU
   is slow and capacity-limited, so the matrix grows slowly.

Meanwhile the opportunity already exists: internal NVIDIA runtimes qualify GPU
clusters today but do **not** yet run `aicr validate`. Extending those
qualifications to emit and publish evidence turns work we already do into public,
verifiable coverage instead of private, transient pass/fail signal.

Goal: signed evidence for every supported recipe permutation, sourced from the
capacity and pipelines we already run.

## Non-Goals

- **Multi-source corroboration as an immediate objective.** Breadth (presence of
  any signed evidence) is prioritized; depth (two or more agreeing signers) is
  deferred to the long tail.
- **Procuring GPU hardware.** Capacity is requested through the usual capacity
  channels; this ADR consumes it. Dedicated capacity is the stated preference but
  not a precondition.
- **The dashboard UI.** Rendering and layout are a separate track.
- **New validator checks** unrelated to coverage.

## Context

- **The dashboard is data-driven.** Building on
  [ADR-012](012-recipe-coordinate-mapping.md), the dashboard auto-discovers
  recipes from `meta.json` objects under
  `gs://aicr-testgrid-staging/results/**`. New coverage appears the moment a
  signed, allowlisted run lands — no renderer or code change.
- **Trust is signature-based.** Consensus counts only bundles whose keyless
  Sigstore signature verifies at ingest and whose signer is allowlisted
  (`recipes/evidence/allowlist.yaml`). A cell reaches CONFIRMED when two or more
  allowlisted signers agree — in the strict per-version view, at the same AICR
  version; the default all-versions view corroborates each signer's latest run
  across versions (weaker).
- **Criteria are runtime-extensible.** The `pkg/recipe/criteria.go` `Parse*`
  functions fall through to a `--data`-seeded registry, so internal pipelines can
  emit evidence for values not in the compiled enum. This is already observed in
  production for out-of-enum service and accelerator values.
- **Producers today.** Four first-party UAT lanes plus two community signers, one
  of them a non-CI (personal-OAuth) producer — already demonstrating that an
  external producer can reach the dashboard end to end.

The breadth denominator is the set of leaf overlays (44 today; the physically
meaningful permutations), not the full Cartesian product of the criteria
dimensions below:

| Dimension | Enumerated values (open-source catalog) |
|---|---|
| Service | `eks` `gke` `aks` `oke` `lke` `bcm` `ocp` `metal3` `kind` |
| Accelerator | `h100` `h200` `gb200` `gb300` `b200` `a100` `l40` `l40s` `rtx-pro-6000` |
| Intent | `training` `inference` |
| OS | `ubuntu` `cos` `ol` `amazonlinux` `rhel` `talos` |
| Platform | `kubeflow` `dynamo` `nim` `slurm` `runai` |

The `--data` registry admits additional internal values at runtime; the
denominator grows as SKUs and services are added.

## Decision

Four decisions.

### 1. Publish evidence from the released binary, into a staging intake path

Add an `aicr evidence ingest` subcommand that uploads a signed evidence bundle
into a **staging intake prefix** of the bucket — reusing `pkg/evidence/verifier`
for an advisory local check plus a GCS SDK writer, and exposing
`Client.IngestEvidence` on `pkg/client/v1`. (Authoritative verification and the
`pkg/evidence/project` synthesis into `results/` are the curator's job, not the
binary's — Decision 2.) The binary writes **only** the intake prefix — never the
tree the dashboard consumes. Internal pipelines
publish with released artifacts alone: no bespoke CI to replicate AICR's ingest,
and no dependency on AICR CI to write on their behalf. We adopt this in-binary
model directly rather than an interim "push to a registry, let AICR CI ingest"
handoff (see Alternatives Considered).

### 2. Two-stage bucket with a promotion curator; CIDR plus a path-scoped writer

The evidence bucket carries two disjoint prefixes: a **staging intake** prefix
(`intake/`) that internal producers may write, and the **results** prefix
(`results/`) the dashboard consumes. Producers reach only intake, gated by two
independent controls — network origin (GCS IP filtering or a VPC-SC perimeter)
and a **writer identity IAM-conditioned to the intake prefix alone**. The
`results/` prefix is writable by **only** the curator.

The **curator is the promotion gate** — the sole process that moves evidence into
the dashboard path. It reads intake, authoritatively verifies each object's
keyless Sigstore signature and allowlist membership, and derives every dashboard
field **solely from cryptographically verified material** — signer identity from
the Fulcio cert SAN, the coordinate from the signature-bound `recipe.yaml`, and the
AICR version and phase counts from the signed predicate — never from
producer-supplied intake framing. It then synthesizes the canonical dashboard
tree, promotes valid evidence into
`results/`, and quarantines the rest; version-aware retention prunes stale
`results/` evidence as AICR versions churn. Any client-side verification the
binary performs is advisory — the curator's server-side verify is authoritative.
(The signature is the sole cryptographic control; any signer-path partitioning is
structural only, per ADR-007/#1535.)

**Intake object form.** A producer uploads a **self-contained signed evidence
bundle** using the summary-bundle layout `aicr validate --emit-attestation`
produces — `recipe.yaml` (whose criteria yield the coordinate), the
`ctrf/<phase>.json` reports, a `manifest.json` sha256 inventory, and optionally
`bom.cdx.json` and a redacted `snapshot.yaml` — plus a DSSE-signed
`attestation.intoto.jsonl`. That signed envelope is **net-new work**: today's
emitter leaves the bundle unsigned (`statement.intoto.json`) and only signs on
`--push`, as an OCI-artifact-subject referrer. The intake path therefore adds a
small **registry-free, content-subject signing step** — reusing the existing
`SignBundle` primitive (present in `pkg/evidence/attestation` but currently unwired
to production) to sign `statement.intoto.json` in place, no OCI push (see the
soundness note below). The result is self-contained: no OCI registry or committed
pointer, so a producer needs only intake-prefix write. The intake key is
producer-chosen and is **never** trusted for identity or coordinate — it only
scopes the upload. (An OCI-ref-pointer form — a small signed pointer referencing a
bundle in a trusted registry, as today's CI ingest uses — was considered; the
self-contained form removes the registry dependency and the second
trusted-registry allowlist from the producer path.)

**Curator verification.** For each intake object the curator, server-side and
authoritatively:

1. **Bounds and parses defensively** — rejects oversized or malformed objects
   before reading (size caps; no symlink or path-traversal object names), reusing
   the bounded-read helpers already in `pkg/evidence`.
2. **Binds content to the signature** — recomputes `manifest.json`'s digest and
   matches it to the **signed predicate's `manifest.digest`**, then verifies every
   file against the manifest and each `ctrf/<phase>.json` against the predicate's
   `ctrfDigest` (closed-world inventory). This content-integrity check rides on the
   signed predicate, not the OCI subject, so no registry access is needed.
3. **Verifies the signature** — validates the DSSE envelope: the Fulcio cert
   chains to the Sigstore trust root, the Rekor transparency-log inclusion proof
   holds, and the signature covers the Statement. This yields the
   **cryptographically verified `(issuer, identity)`** from the cert SAN — the only
   trusted source of signer identity.
4. **Classifies against the allowlist** — `allowlist.Classify(issuer, identity)`
   on the *verified* pair. Allowlisted → the run counts for consensus;
   verified-but-unlisted → recorded as a zero-weight "reported" run;
   unverifiable → quarantined.
5. **Derives coordinate and fields from the verified predicate** — recipe
   coordinate, AICR version, k8s version, and per-phase pass/fail counts come from
   the signed predicate and verified `recipe.yaml`, never from the intake key or
   filenames.
6. **Synthesizes and promotes** — writes the canonical
   `results/<service>/<accelerator-os>/<intent[-platform]>/<idHash>/<runId>/`
   `{meta.json, ctrf/}` atomically. Both path-forming segments derive from
   *verified* material, never the intake key: `idHash` from the verified
   `(issuer, identity)`, and `runId` as `run-<attestedAt>` (from the signed
   predicate, so it orders chronologically in the dashboard's builds-over-time
   view) with a bundle-digest suffix for idempotence: an identical re-uploaded
   bundle resolves to the same `runId` (a safe no-op re-promote), and the suffix is
   sized for collision-resistance within a signer's own subtree (per the 128-bit
   rationale in `pkg/evidence/project/idhash.go`). The run is then live on the
   dashboard.

Validating without the OCI artifact is sound: the DSSE signature covers the whole
in-toto Statement, and the **predicate** — not the in-toto subject — carries the
content commitment (`manifest.digest` → per-file sha256, per-phase `ctrfDigest`,
and the recipe digest), which is exactly what `verifier.Verify`'s manifest-hash
check binds. Today's `--push` signs an *OCI-artifact-subject* Statement
(subject = the pushed artifact's digest) so `cosign verify-attestation` can
discover it as an OCI referrer, and that subject cannot be re-derived without the
artifact. The self-contained intake path therefore signs the **content-subject**
Statement instead (subject = `sha256(canonicalize(recipe.yaml))`, which the
emitter already persists unsigned as `statement.intoto.json`), so subject and
payload are both content-addressed and verifiable offline; the OCI-referrer form
stays for `--push` / registry consumers.

This generalizes today's ingest, which pins one `--expected-identity-regexp` per
run (`verifier.Verify`): the curator instead verifies first and then matches the
verified identity against the whole allowlist, so any allowlisted signer can
deposit without a per-object pin — the allowlist *is* the pin-set. Nothing a
producer writes into intake — path, filenames, or unsigned fields — influences
identity, coordinate, or consensus.

The layered controls bound a producer by state. **Unauthorized** (no writer
identity, or outside the CIDR perimeter) → cannot write even intake.
**Un-allowlisted and unverifiable** → quarantined in intake, never promoted.
**Un-allowlisted but cryptographically verified** → promoted to `results/` as a
**zero-weight "reported" run**: visible on the dashboard but carrying no consensus
weight (it can never reach SINGLE or CONFIRMED). Only an **allowlisted** signer
carries weight, and that is a deliberate trust grant (see Consequences). Trust
rides on the signature and the allowlist, not the writer; the residual exposure is
display noise from the verified-but-unlisted case, which the intake-abuse open
question owns.

### 3. Feed breadth from internal qualifications; dedicate UAT where capacity allows

Primary breadth comes from **extending internal qualification pipelines** to run
`aicr validate` + `aicr evidence ingest` on capacity they already hold, including
frontier SKUs admitted via the `--data` registry. Dedicated AICR UAT lanes remain
the higher-fidelity path wherever a reserved pool can be secured, but they are not
the gate. Some SKUs (notably rack-scale accelerators) may never be dedicated and
will be covered by the extended internal quals or by timeshare.

### 4. Two workstreams

The work divides by owning org, meeting at the publish pipe and at capacity
handoffs:

- **AICR (open-source repo):** the in-binary ingest, the two-stage bucket layout
  and promotion curator, the signer allowlist, recipe overlays for new
  SKUs/services/platforms, dedicated UAT lanes, and the coverage scoreboard.
- **Internal:** **extending qualification pipelines** to emit evidence
  (`aicr validate --emit-attestation`) and get it signed and into intake — the
  signing path is an open question, since the quals run on self-hosted GitLab —
  making that a standing gate in release pipelines, and securing dedicated capacity
  where possible.

## Consequences

- The curator is the **sole writer to `results/` and the sole cryptographic gate**
  for the dashboard: the generator trusts the promoted `meta.json` as-is and does
  not re-run Sigstore verification, so `results/` integrity rests on this one
  process. Its compromise is therefore an **integrity** risk, not merely an
  availability one — the curator's hosting, run identity, and code provenance need
  a threat-model treatment (open question). Of the three controls, only the
  curator's verify protects `results/`; CIDR and the intake-scoped writer identity
  only gate the staging prefix.
- Producer blast radius is bounded by state: unauthorized producers cannot write
  intake; un-allowlisted *unverifiable* deposits are quarantined; un-allowlisted but
  *verified* deposits reach `results/` only as **zero-weight "reported" runs**
  (dashboard display noise, never consensus weight). **Allowlisted** producers are
  the real trust grant: the curator verifies provenance, not validator verdicts (an
  ADR-007 non-goal), so any one allowlisted producer can inflate breadth with a fake
  SINGLE cell or poison a real cell to CONTESTED. Decision 3 broadens the allowlisted
  set well beyond today's four pinned UAT lanes, so allowlist membership is a trust
  decision and per-signer coordinate scoping is worth considering.
- The two-stage layout **preserves** [ADR-007](007-recipe-evidence.md)'s
  separation of untrusted deposit from trusted publish — re-expressed as the
  `intake/` vs `results/` prefixes — and relocates today's CI-side verify/publish
  jobs (`evidence-ingest.yaml`) into the curator rather than collapsing verify and
  publish into one process. It does replace a git-committed, PR-reviewed
  community-deposit surface with a mutable bucket prefix.
- Adds the first cloud SDK dependency (`cloud.google.com/go/storage`) to a binary
  that today has no cloud-SDK footprint — a supply-chain surface to weigh against
  shelling out to `gcloud` (the incumbent repo pattern, which needs `gcloud` on
  the producer host).
- Breadth-before-depth means many cells stay single-source for a while. The
  scoreboard must distinguish "no capacity / not yet run" from "run but not yet
  corroborated" — and only the phase-2 capacity inventory can supply the former,
  so the two must be wired together.
- If internal quals sign under a **single shared identity**, internal-qual-only
  SKUs reach breadth but never CONFIRMED (consensus needs two *distinct*
  allowlisted signers) — so depth for exactly those SKUs is structurally
  unreachable, not merely deferred, without a second independent signer.
- Dedicated capacity is not guaranteed for every SKU; some cells will be
  internal-qual-only, with the higher-fidelity dedicated lane arriving later or
  never.

## Alternatives Considered

- **Model 1 — registry handoff.** Internal pushes a signed bundle to a registry
  and AICR CI ingests it. Least internal build effort and needs no bucket access
  at all, but keeps every internal producer dependent on AICR CI to publish.
  Rejected as the target (may remain a stopgap during the pipe build).
- **Model 2 — internal replicates the CI publish pipeline.** Internal stands up
  its own verify → GCS write. Most internal effort for no strategic gain, and
  duplicates logic that already lives in AICR libraries. Rejected.
- **Per-pipeline identity federation** instead of CIDR. Stronger IAM isolation,
  but high management overhead per producer and unnecessary once trust rides on
  the in-bundle signature rather than the writer principal. Held as the fallback
  if CIDR/VPC-SC does not meet the security bar.
- **Corroboration-first.** Prioritize depth (second signers) before breadth.
  Rejected: presence of any signed evidence is the immediate goal; multi-source
  corroboration becomes the interesting question only once breadth is broad.

## Adoption plan

Critical path: build the pipe → feed from internal quals → harden and dedicate →
pursue depth.

1. **Build the pipe** *(gates everything).* AICR delivers `aicr evidence ingest`
   (the registry-free content-subject signing mode + upload to intake), the
   two-stage bucket layout with the path-scoped writer identity and CIDR perimeter,
   and the promotion curator — this deliverable *defines* the curator's run
   identity, code-provenance pinning, and intake/quarantine GC + object-size caps
   (the items the Open questions flag), plus the internal-signer allowlist entries.
   Under the recommended two-phase path (Open questions), AICR also owns the
   tightly-scoped **GitHub Actions signing leg** that turns a GitLab `--no-sign`
   bundle into a signed intake object; Internal delivers the GitLab
   `--emit-attestation --no-sign` step and egress to that leg. Exit criteria: one
   `GitLab emit → sign → aicr evidence ingest` run lands in intake and the curator
   promotes it into `results/` and onto the dashboard.
2. **Light up breadth via internal quals.** This phase opens with a **capacity
   inventory** (tracked as its own issue): a complete accounting of GPU × service
   capacity reachable for coverage — internal qualification capacity, dedicated
   pools, and timeshare alike — mapping each pool to the recipe coordinates it
   would unlock. That inventory, not this ADR, determines the specific
   SKU/service targets and their sequencing. Internal then extends its
   qualification pipelines to run `aicr validate` + `aicr evidence ingest`,
   producing single-source coverage for the SKUs it qualifies (including
   out-of-enum SKUs via `--data`); AICR authors the overlays those coordinates
   need and stands up the coverage scoreboard.
3. **Harden and add dedicated UAT.** Internal makes AICR qualification a standing
   release-pipeline gate and secures dedicated pools where possible. AICR restores
   the inference serve-path CUJ ([#1644](https://github.com/NVIDIA/aicr/issues/1644))
   and adds dedicated UAT lanes for SKUs where a pool landed.
4. **Long tail.** Corroboration (second signers → CONFIRMED), remaining on-prem
   coverage (BCM / OCP / Metal3), enum-only stragglers, and retention-policy
   tuning on the curator.

Specific SKU and service targets — and whether each needs an overlay, an
enum addition, or only capacity — fall out of the phase-2 capacity inventory
rather than being fixed here.

Open questions:

- **Curator integrity and cadence** — where the curator runs, under what identity,
  and how its code provenance is pinned (it is the sole cryptographic gate for
  `results/`); and whether the promotion pass runs before each dashboard build
  (simplest) or continuously (faster, more infra). Leaning per-build to start.
- **Internal signer identity (the quals run on self-hosted GitLab).** Keyless
  Sigstore requires a **Fulcio-trusted issuer**; public-good Fulcio trusts GitHub
  Actions and `gitlab.com` (SaaS), but **not** a self-hosted GitLab instance's
  issuer, and a GitLab job cannot mint a GitHub OIDC token — so "just use GitHub
  OIDC" does not apply directly. (Fulcio is issuer-configurable and supports many
  issuers; the real constraints are that public-good Fulcio only trusts *public,
  curated* issuers — never a private instance — and that whatever Fulcio mints the
  cert, the **public dashboard verifier must trust its CA + Rekor + TUF root**.)
  Three paths, in rough order of increasing lift:
  1. **Two-phase sign (recommended start).** GitLab runs `aicr validate
     --emit-attestation --no-sign`; a small, tightly-scoped **GitHub Actions** leg
     signs the bundle (GitHub OIDC → Fulcio) and uploads to intake. This reuses
     AICR's two-phase *shape* (`evidence-publish.yaml` — offline emit, then a
     Fulcio-reachable signing leg) and the existing GitHub allowlist grammar with
     **no allowlist code change** — but the signing itself is the new registry-free
     content-subject mode (Intake object form), not today's push-then-referrer
     `aicr evidence sign`. Caveat: the signed identity attests the *signing
     workflow*, not the GitLab job — provenance is "came through our trusted signing
     pipeline," so that workflow must be tightly scoped.
  2. **GitLab identity + internal Sigstore.** Stand up an internal Fulcio/Rekor
     trusting the self-hosted GitLab issuer so the qual job signs under its own
     identity (strongest provenance). Cost: operate an internal Sigstore stack, make
     the *public* dashboard verify/corroborate path trust that internal trust root
     alongside public-good, and extend `pkg/evidence/allowlist` `checkNotOverBroad`
     (hardcoded to GitHub's `<workflow>@<ref>` grammar) for GitLab's subject format —
     a security-reviewed change, not an allowlist row.
  3. **Keyed signing.** A long-lived key held by the pipeline, public key
     allowlisted. Simplest for GitLab, but AICR is keyless-only today; adding it
     drops the transparency-log identity binding.

  The per-signer-scoping and single-shared-identity consequences above bear on
  whichever path is chosen.
- **Intake abuse, quarantine, and cost** — object-size caps and per-identity quotas
  on `intake/` (advisory client verify means the binary uploads even invalid
  bundles), a quarantine TTL and purge owner, and a storage-cost budget. `results/`
  retention is version-aware, but `intake/`/quarantine GC is not yet specified.
- **CIDR sufficiency** — confirm GCS IP filtering / VPC-SC meets the security bar
  for a shared writer principal; the fallback is per-pipeline identities.

## References

- Dashboard renderer and generator: `pkg/corroborate/`; ingest + publish workflows
  `.github/workflows/evidence-ingest.yaml` and `evidence-dashboard-publish.yaml`;
  bucket `gs://aicr-testgrid-staging`, prefix `results/`.
- Evidence emit/verify/ingest: `pkg/evidence/{attestation,verifier,project}`;
  `pkg/cli/validate_evidence.go`, `pkg/cli/evidence*.go`; producers
  `tools/evidence-project`, `tools/corroborate`.
- Signer allowlist: `recipes/evidence/allowlist.yaml`, `pkg/evidence/allowlist`.
- Recipes: `pkg/recipe/criteria.go`, `recipes/overlays/`, `recipes/registry.yaml`.
- UAT: `.github/workflows/uat-*.yaml`, `infra/uat/reservations.yaml`,
  `pkg/uatbroker`, `tests/uat/`.
- Related ADRs: [ADR-007](007-recipe-evidence.md),
  [ADR-009](009-recipe-health-tracking.md),
  [ADR-012](012-recipe-coordinate-mapping.md).
- Related issues: [#1644](https://github.com/NVIDIA/aicr/issues/1644) (inference
  serve-path), [#1505](https://github.com/NVIDIA/aicr/issues/1505) (community
  ingest loader), [#1789](https://github.com/NVIDIA/aicr/issues/1789) (per-intent
  nightly enrollment gate).
