<!--
Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Renovate

Renovate replaces Dependabot for dependency updates and additionally tracks the tool versions pinned in [`.settings.yaml`](../.settings.yaml) (the project's single source of truth) — something Dependabot cannot do.

Configuration: [`.github/renovate.json5`](renovate.json5)
Workflow: [`.github/workflows/renovate.yaml`](workflows/renovate.yaml)
Companion script: [`tools/update-chainsaw-checksums`](../tools/update-chainsaw-checksums)

## Architecture

Self-hosted via `renovatebot/github-action`, scheduled weekly (Mondays 09:00 UTC) plus `workflow_dispatch`. Auth is the built-in `secrets.GITHUB_TOKEN`; the repo's `/ok` reviewer-comment policy re-fires CI on bot PRs, sidestepping GitHub's "GITHUB_TOKEN cannot trigger workflows" limitation. Pattern matches [`NVIDIA/gpu-operator`](https://github.com/NVIDIA/gpu-operator/blob/main/.github/workflows/renovate.yaml).

### Coverage

| Source | Manager |
|---|---|
| `go.mod` | `gomod` (groups: `kubernetes`, `golang-x`, `opencontainers` — preserved from Dependabot) |
| `.github/workflows/*.yaml`, `.github/actions/*/action.yml` | `github-actions` (digest-pinned via `helpers:pinGitHubActionDigests`; grouped into one PR/cycle) |
| `validators/*/Dockerfile` | `dockerfile` |
| `infra/**/*.tf` | `terraform` (grouped into one PR/cycle) |
| `site/package.json` | `npm` |
| `recipes/components/*/values.yaml` | `helm-values` (auto-detect `image.repository`/`image.tag` shapes — partial, see below) |
| `.settings.yaml` (~28 tools) | custom regex manager (this file's `# renovate:` annotations) |
| `.settings.yaml` git-refs SHAs (`nvkind`) | dedicated git-refs digest customManager (`# renovate-digest:` annotations) |
| `.settings.yaml` chainsaw checksums | `postUpgradeTasks` invokes `tools/update-chainsaw-checksums` |

The `go` directive in `go.mod` is intentionally not bumped by Renovate; the Go toolchain version is owned by `.settings.yaml.languages.go`.

**Coverage delta vs Dependabot:** Dependabot tracked `gomod`, `github-actions`, Dockerfile-only `docker`, and `terraform`. Renovate adds: `npm` (site), `helm-values` (chart values), the entire `.settings.yaml` tool set via the custom regex manager, and the chainsaw post-upgrade hook.

### Patch auto-merge

Auto-merge is opt-in and narrower than the previous `dependabot-auto-merge.yaml` blanket rule. Patch / pin / digest updates auto-merge for:

- `github-actions`, `gomod`, `npm` — low-blast-radius managers.
- An explicit allow-list of `.settings.yaml` tools: build/lint/security tooling (`goreleaser`, `ko`, `crane`, `git-cliff`, `golangci-lint`, `yamllint`, `addlicense`, `go-licenses`, `grype`, `syft`, `cosign`, `yq`).

Cluster-impacting pins — `helm`, `kubectl`, `kind`, `kwok`, `chainsaw`, `karpenter`, `gpu-operator`, `kindest/node`, CUDA, the Go toolchain, `node`, `hugo`, and `nvkind` — always require human review, even on patch bumps.

### Schedule

Renovate runs `before 6am every weekday` (UTC) plus on-demand via `workflow_dispatch`. Self-hosted Renovate cannot ingest GitHub vulnerability alerts (that's a Mend-hosted feature), so weekday cadence narrows the window between an upstream CVE landing and the bump PR appearing.

## How to add a new pin to `.settings.yaml`

Add a `# renovate: …` comment on the line directly above the value. Three annotation shapes are supported by the broad regex manager. Each annotation **must** include a `depType=<section>` parameter naming the top-level YAML section it sits under (e.g. `build_tools`, `testing_tools`) — the `packageRules` use this to bundle PRs by section.

```yaml
# A) Plain version string (no embedded ':')
# renovate: datasource=github-releases depName=owner/repo depType=build_tools
mytool: 'v1.2.3'

# B) Docker image with embedded tag — captures only the tag for renovate
# renovate: datasource=docker depName=registry.example.com/path/image depType=testing
mytool_image: 'registry.example.com/path/image:1.2.3'

# C) YAML list item (also captures plain quoted scalars)
some_list:
  # renovate: datasource=github-releases depName=owner/repo depType=build_tools
  - 'v1.2.3'
```

`depType` must come immediately after `depName` (the regex captures it as the next whitespace-separated token). Other metadata (`extractVersion`, `versioning`, `registryUrl`) follows.

Block scalars (`|` / `>`) and unquoted values are not supported — keep version pins as quoted scalars.

Optional metadata (`extractVersion`, `versioning`, `packageNames`, `registryUrls`) goes in [`renovate.json5`](renovate.json5)'s `packageRules` keyed off `matchDepNames`, not in the annotation comment — keeps the regex simple.

### Tracking a git-refs SHA (e.g., a main-branch commit)

For tools pinned by 40-char commit SHA (no upstream releases), use the `# renovate-digest:` prefix and a separate `branch=` parameter. The dedicated git-refs customManager captures the SHA into `currentDigest` and tracks the named branch for new commits:

```yaml
# renovate-digest: datasource=git-refs depName=mytool packageName=https://github.com/owner/repo branch=main depType=testing_tools
mytool: '1234567890abcdef1234567890abcdef12345678'
```

The distinct prefix (`# renovate-digest:` vs `# renovate:`) keeps the broad regex from also matching this annotation. Include `depType=` so the digest PR is grouped with its section's tooling rather than landing alone.

After editing, validate locally: `make lint-renovate` (requires Docker — runs the same `ghcr.io/renovatebot/renovate:43` image used by the workflow). CI re-runs this same target via `merge-gate.yaml` whenever `.github/renovate.json5` changes; PRs that don't touch the file skip it.

## Verification plan (post-merge soft-launch)

This config is shipped alongside Dependabot. Don't delete `.github/dependabot.yml` until the soft-launch phases below confirm Renovate works end-to-end.

### Phase A — Local static checks

1. `make lint-renovate` (validates the JSON5 against the Renovate schema).
2. `make lint` (full lint chain — yamllint sees the new `# renovate:` comments).
3. `make qualify` (broader gate; unaffected since no version values changed).
4. Sanity-check `.github/actions/load-versions/action.yml` still parses `.settings.yaml`:
   ```sh
   yq eval '.testing_tools.chainsaw'           .settings.yaml  # → v0.2.14
   yq eval '.testing_tools.chainsaw_checksums' .settings.yaml
   ```

### Phase B — Docker dry-run (full discovery, no PRs)

```sh
docker run --rm \
  -e LOG_LEVEL=debug \
  -e RENOVATE_TOKEN="$GITHUB_TOKEN" \
  -e RENOVATE_DRY_RUN=full \
  -e RENOVATE_REPOSITORIES='["NVIDIA/aicr"]' \
  -v "$PWD:/usr/src/app" \
  renovate/renovate:slim
```

Confirm in the output:
- One detected dependency per `# renovate:` annotation in `.settings.yaml` (~22 entries).
- `gomod`, `github-actions`, `dockerfile`, `terraform`, `npm`, and the custom regex manager all report file counts > 0.
- The simulated chainsaw upgrade run shows an attempt to invoke `./tools/update-chainsaw-checksums`.
- No `WARN: Custom manager fileMatch but no dependencies found` for our `customManagers`.

If a `.settings.yaml` annotation is missed, iterate on the `matchStrings` regex in [`renovate.json5`](renovate.json5).

### Phase C — Post-upgrade script standalone test

```sh
./tools/update-chainsaw-checksums v0.2.14   # currently pinned → expect zero diff
./tools/update-chainsaw-checksums v0.2.15   # next release → exercise the upgrade path
git diff .settings.yaml                      # only the four checksums + chainsaw version should change
git checkout -- .settings.yaml
```

Failure modes to watch for: missing `darwin_*` entries in upstream `checksums.txt`, yq formatting diffs (block-vs-flow), trailing whitespace.

### Phase D — Soft-launch on the live repo

1. Merge this PR — Renovate config lands alongside Dependabot. **Do not delete `.github/dependabot.yml` yet.**
2. Manually trigger Renovate: `gh workflow run renovate.yaml`. Watch logs with `gh run watch`.
3. Verify:
   - Workflow exits 0.
   - A "Dependency Dashboard" issue is opened (or updated) listing every discovered dependency.
   - First wave of update PRs lands with `chore(deps):` titles and the `dependencies` label.
   - Reviewers `/ok` the PRs to fire CI; CI is green for trivially-safe updates.
4. Force a `.settings.yaml` bump end-to-end: on a throwaway branch, lower one version (e.g. `golangci_lint: 'v2.10.0'`) and re-run Renovate against that branch via `RENOVATE_BASE_BRANCHES`. Expect a PR bumping it back. Discard the branch.
5. Verify `postUpgradeTasks` end-to-end: either wait for an organic chainsaw release > v0.2.14, or lower `chainsaw: 'v0.2.13'` on a throwaway branch and confirm Renovate's PR includes both the version bump AND the four checksum updates produced by the script.
6. Confirm patch auto-merge by leaving a low-risk patch PR alone and watching it auto-merge after CI completes.

### Phase E — Cutover

Open a follow-up PR removing:
- `.github/dependabot.yml`
- `.github/workflows/dependabot-auto-merge.yaml`

Reference the Phase D run IDs in the PR description as evidence. Then monitor the first full week post-cutover for:
- PR backlog growth (tune `prConcurrentLimit` / `prHourlyLimit`).
- False-positive bumps (e.g., wrong datasource picking up a release-candidate tag → add `allowedVersions`).
- Any pin that didn't get a renovate annotation (grep `git log --since=…` for hand-bumps).

## Known limitations

- **AWS EFA device-plugin image (`recipes/components/aws-efa/values.yaml`)** is published only to AWS's authenticated public ECR (`602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/aws-efa-k8s-device-plugin`); there is no `public.ecr.aws` mirror. Renovate without AWS credentials cannot enumerate tags, so the image is in `ignoreDeps`. Bumps are tied to AWS releasing a new EKS add-on version and need to be handled manually.
- **`recipes/components/*/values.yaml`** is partially covered. Renovate's built-in `helm-values` manager picks up the conventional `image: { repository, tag }` shape but won't auto-detect arbitrary chart-value version fields. To extend coverage, add `# renovate:` annotations directly to those files (the customManager only scans `.settings.yaml` today).
- **`extractVersion` rules** rely on `matchDepNames`. If you add a tool whose upstream releases are tagged `vX.Y.Z` but the value in `.settings.yaml` is bare `X.Y.Z`, add it to the existing `extractVersion: "^v(?<version>.+)$"` rule's `matchDepNames` list.
- **No vulnerability fast-path.** Self-hosted Renovate cannot consume GitHub vulnerability alerts (that's a Mend-hosted feature). The weekday schedule is the mitigation.
- **The Renovate runner image (`ghcr.io/renovatebot/renovate`) is not yet auto-managed.** It's referenced in two places — the `RENOVATE_VALIDATOR_IMAGE` variable in `Makefile` (used by `verify-renovate` in `merge-gate.yaml`) and the `renovate-version: '43@sha256:...'` input in `.github/workflows/renovate.yaml` — and both digest pins must be bumped manually in lockstep. The customManager regex in `renovate.json5` doesn't currently capture `image:tag@sha256:...` shapes; future work could extend it so Renovate self-bumps these.
