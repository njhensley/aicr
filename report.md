# Public Repository Audit Report

**Repository:** NVIDIA/aicr
**Date:** 2026-03-09
**Branch:** main (commit d57abab6)
**Scope:** Full codebase scan + git history review

---

## Summary

Audit of the AICR codebase and repository history for NVIDIA-internal content that should not be present in a public repository. Findings are categorized by severity.

| Severity | Count |
|----------|-------|
| Critical | 6 |
| High | 4 |
| Medium | 4 |
| Low / Acceptable | 10 |

---

## Critical — Must Fix

### 1. Internal GitLab URL

- **File:** `examples/data/registry.yaml:35`
- **Content:**
  ```yaml
  defaultSource: https://gitlab-master.nvidia.com/dgxcloud/mk8s/components/dgxc-teleport.git
  ```
- **Issue:** References NVIDIA internal GitLab instance (`gitlab-master.nvidia.com`). Not accessible to the public.
- **Recommendation:** Replace with a public repository URL or remove the component from examples.

### 2. Internal `dgxc.io` Domain — Site Base URL

- **File:** `site/hugo.yaml:15`
- **Content:**
  ```yaml
  baseURL: https://aicr.dgxc.io/
  ```
- **Issue:** `dgxc.io` is an internal NVIDIA domain for DGXCloud infrastructure. Not publicly resolvable.
- **Recommendation:** Replace with a public documentation URL or a placeholder.

### 3. Internal `dgxc.io` Domain — GitHub Action

- **File:** `.github/actions/build-versioned-site/action.yml` (lines 91, 144, 175)
- **Content:**
  ```yaml
  yq eval -i '.baseURL = "https://aicr.dgxc.io/"' ...
  ```
- **Issue:** Hardcoded internal domain in CI/CD build step.
- **Recommendation:** Replace with public domain or parameterize via workflow input.

### 4. Internal Demo API URLs

- **Files:** `demos/data.md` (lines 198, 204), `demos/e2e.md` (lines 69, 75, 90, 150-151)
- **Content:**
  ```
  curl -s "https://aicr-demo.dgxc.io/v1/recipe?service=eks&accelerator=gb200&intent=training"
  curl -s -X POST "https://aicr-demo.dgxc.io/v1/bundle?deployer=argocd"
  ```
- **Issue:** Internal demo/staging API endpoints not accessible to the public.
- **Recommendation:** Replace with `localhost` examples, placeholder URLs, or remove.

### 5. AWS Account ID

- **File:** `tests/uat/aws/config.yaml:20`
- **Content:**
  ```yaml
  tenancy: "615299774277"
  ```
- **Issue:** Real 12-digit AWS account ID exposed. Can be used for reconnaissance or account-specific attacks.
- **Recommendation:** Replace with placeholder (e.g., `"123456789012"`).

### 6. AWS Infrastructure IDs

- **File:** `tests/uat/aws/config.yaml:81,86`
- **Content:**
  ```yaml
  imageId: ami-08c586949b8b85f80
  target: cr-0cbe491320188dfa6
  ```
- **Issue:** Real AWS AMI ID and Capacity Reservation ID specific to an NVIDIA AWS account.
- **Recommendation:** Replace with placeholders (e.g., `ami-0123456789abcdef0`).

---

## High — Should Fix

### 7. Internal Teleport Proxy

- **File:** `examples/data/components/dgxc-teleport/values.yaml:22,31,92`
- **Content:**
  ```yaml
  # proxyAddr: nv-stg-dgxc.teleport.sh:443 (staging)
  proxyAddr: nv-stg-dgxc.teleport.sh:443
  audience: nv-stg-dgxc.teleport.sh
  ```
- **Issue:** References NVIDIA internal Teleport staging proxy (`nv-stg-dgxc`). Reveals internal access control infrastructure.
- **Recommendation:** Replace with placeholder values or remove the entire dgxc-teleport example.

### 8. Network CIDR Allowlists

- **File:** `tests/uat/aws/config.yaml:36-61`
- **Content:**
  ```yaml
  - 216.228.127.128/30  # CSV4
  - 52.41.222.58/32     # US Northwest
  - 54.68.11.139/32     # US Northwest
  - 10.0.1.0/27
  - 10.0.2.0/27
  # ... additional specific CIDRs
  ```
- **Issue:** Specific public and private IP ranges used in production infrastructure. Enables network reconnaissance.
- **Recommendation:** Replace with generic example CIDRs (e.g., `10.0.0.0/16`, `203.0.113.0/24`).

### 9. Internal K8s Components in Example Snapshots

- **Files:** `examples/snapshots/h100.yaml`, `examples/snapshots/gb200.yaml`
- **Content:**
  ```yaml
  dgxc-admission-controller: 1.865.0
  # Namespaces: dgxc-controller, dgxc-janitor-system, dgxc-logging, dgxc-storage
  ```
- **Issue:** DGXc-specific Kubernetes components and system namespaces expose internal architecture.
- **Recommendation:** Scrub DGXc-specific component names from example snapshots, or clearly document them as NV-internal examples.

### 10. Internal Enterprise Container Image

- **File:** `examples/data/components/dgxc-teleport/values.yaml:45`
- **Content:**
  ```yaml
  enterpriseImage: nvcr.io/nvidia/teleport-ent-distroless
  ```
- **Issue:** References a proprietary enterprise Teleport image on NVCR that may not be publicly accessible.
- **Recommendation:** Verify public availability or replace with placeholder.

---

## Medium — Should Review

### 11. DGXc Teleport Overlay Configuration

- **File:** `examples/data/overlays/dgxc-teleport.yaml`
- **Issue:** Entire file is NV-internal Teleport overlay configuration. Not useful to external users.
- **Recommendation:** Remove or replace with a generic overlay example.

### 12. Prometheus Default Password

- **File:** `recipes/components/kube-prometheus-stack/values.yaml:52`
- **Content:**
  ```yaml
  adminPassword: admin  # Change in production
  ```
- **Issue:** Weak default password. While commented, it will be deployed as-is if not overridden.
- **Recommendation:** Use a stronger placeholder or require explicit `--set` override.

### 13. AWS ELB Hostname in Evidence

- **File:** `docs/conformance/cncf/evidence/inference-gateway.md`
- **Content:** Real AWS ELB DNS name (`a190c6734e7d3416883754566d933798-665417928.us-east-1.elb.amazonaws.com`)
- **Issue:** Reveals infrastructure details of a specific test cluster. If still active, the hostname could be probed.
- **Recommendation:** Redact or replace with placeholder.

### 14. Demo Docs Reference Internal Components

- **Files:** `demos/data.md:227`, `demos/e2e.md:227,244,246`
- **Content:** References to `dgxc-teleport` overlay and internal component examples.
- **Issue:** Documents internal DGXc components in public-facing demos.
- **Recommendation:** Remove internal component references from demo docs.

---

## Low / Acceptable — No Action Required

| Item | Location | Assessment |
|------|----------|------------|
| `@nvidia.com` author emails in git log | Git history | Expected for NVIDIA OSS project |
| `nvcr.io/nvidia/cuda:*` image references | Multiple files | Public NGC registry images |
| `helm.ngc.nvidia.com/nvidia` | Multiple files | Public Helm chart repository |
| `aicr.nvidia.com/v1alpha1` API group | Multiple files | Expected project API identifier |
| `GitHub_Conduct@nvidia.com` | `CODE_OF_CONDUCT.md` | Public contact email |
| `aicr-maintainers@nvidia.com` | `docs/conformance/cncf/submission/PRODUCT.yaml` | Public maintainer contact |
| Apache 2.0 license + copyright headers | All source files, `LICENSE` | Correct for public OSS |
| Semver tags (v0.1.0 – v0.9.12) | Git tags | Clean, standard versioning |
| Commit messages | Git history (300+ commits) | No internal references found |
| Deleted files in history | `.envrc` (stub), `hf-token-secret.yaml` (template) | No real secrets committed |
| `GITLAB_TOKEN` in CLAUDE.md/AGENTS.md | Documentation | Only referenced as `unset` instruction |
| AWS public ECR account (`602401143452`) | `recipes/components/aws-efa/values.yaml` | AWS-owned public account for EKS add-ons |
| Branch names | 22 remote branches | No internal references |

---

## Unverified — Manual Review Needed

### GitHub Releases, Issues, and PRs

The `gh` CLI encountered a TLS certificate verification error during this audit, preventing automated review of:

- Release notes (20 releases)
- Issue descriptions and comments
- PR descriptions and comments

**Action:** Manually review via the GitHub web UI at https://github.com/NVIDIA/aicr for any internal references in issue/PR/release content.

---

## Recommended Action Plan

### Priority 1 — Before Public Traffic

1. **Sanitize `tests/uat/aws/config.yaml`** — Replace real AWS account ID, AMI, capacity reservation, and specific CIDR allowlists with placeholders.
2. **Replace all `dgxc.io` references** — `site/hugo.yaml`, `.github/actions/build-versioned-site/action.yml`, `demos/data.md`, `demos/e2e.md`.
3. **Remove `gitlab-master.nvidia.com` URL** — Replace with public source or placeholder in `examples/data/registry.yaml`.

### Priority 2 — Short Term

4. **Remove or genericize dgxc-teleport example** — The entire `examples/data/components/dgxc-teleport/` directory, `examples/data/overlays/dgxc-teleport.yaml`, and related demo references.
5. **Scrub DGXc-specific components from example snapshots** — Or add documentation noting these are NV-internal component names.
6. **Redact ELB hostname from evidence docs** — If the test cluster is still active.

### Priority 3 — Housekeeping

7. **Change Prometheus default password** — Use a stronger placeholder.
8. **Manually review GitHub releases/issues/PRs** — Check for internal references in descriptions and comments.
9. **Add CI secret scanning** — Consider adding a pre-commit hook or CI step to detect internal URL patterns (e.g., `gitlab-master.nvidia.com`, `*.dgxc.io`, `nv-stg-*`).

---

## Files Requiring Changes

| File | Issues |
|------|--------|
| `tests/uat/aws/config.yaml` | #5, #6, #8 |
| `examples/data/registry.yaml` | #1 |
| `examples/data/components/dgxc-teleport/values.yaml` | #7, #10 |
| `examples/data/overlays/dgxc-teleport.yaml` | #11 |
| `examples/snapshots/h100.yaml` | #9 |
| `examples/snapshots/gb200.yaml` | #9 |
| `site/hugo.yaml` | #2 |
| `.github/actions/build-versioned-site/action.yml` | #3 |
| `demos/data.md` | #4, #14 |
| `demos/e2e.md` | #4, #14 |
| `recipes/components/kube-prometheus-stack/values.yaml` | #12 |
| `docs/conformance/cncf/evidence/inference-gateway.md` | #13 |
