# Release Process

This document outlines the release process for NVIDIA Eidos. For contribution guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Prerequisites

- Repository admin access with write permissions
- Understanding of semantic versioning (vMAJOR.MINOR.PATCH)
- Access to GitHub Actions workflows

## Release Methods

### Method 1: Automatic Release (Recommended)

For standard releases from the main branch.

**Steps**:

1. **Ensure main is ready**:
   ```bash
   git checkout main
   git pull origin main
   make qualify  # All checks must pass
   ```

2. **Create and push a version tag**:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

3. **Automatic workflows trigger** (via `on-tag.yaml`):
   - Go CI validates code quality (tests, lint)
   - GoReleaser builds binaries and container images
   - SBOM generation for all artifacts
   - Attestations signed with Sigstore
   - GitHub Release created with changelog
   - Demo Cloud Run deployment (eidosd API server example)

4. **Verify artifacts** (see [Verification](#verification) below)

### Method 2: Version Bump Helpers

For convenience, use Makefile targets:

```bash
make bump-patch   # v1.2.3 → v1.2.4
make bump-minor   # v1.2.3 → v1.3.0
make bump-major   # v1.2.3 → v2.0.0
```

These create and push the tag automatically.

### Method 3: Manual Workflow Trigger

For rebuilding from existing tags or emergency releases:

1. Navigate to **Actions** → **On Tag Release**
2. Click **Run workflow**
3. Enter the existing tag (e.g., `v1.2.3`)
4. Click **Run workflow**

## Workflow Pipeline

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ Tag Push │───▶│  Go CI   │───▶│  Build   │───▶│  Attest  │───▶│  Deploy  │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
                  tests +         binaries +      SBOM +          Demo Deploy
                  lint            images          provenance      (example)
```

## Released Components

### Binaries

Built via GoReleaser for multiple platforms:

| Binary | Platforms | Description |
|--------|-----------|-------------|
| `eidos` | darwin/amd64, darwin/arm64, linux/amd64, linux/arm64 | CLI tool |
| `eidosd` | linux/amd64, linux/arm64 | API server |

### Container Images

Published to GitHub Container Registry (`ghcr.io/nvidia/`):

| Image | Base | Description |
|-------|------|-------------|
| `eidos` | `nvcr.io/nvidia/cuda:13.1.0-runtime-ubuntu24.04` | CLI with CUDA runtime |
| `eidosd` | `gcr.io/distroless/static:nonroot` | Minimal API server |

Tags: `latest`, `v1.2.3`

### Supply Chain Artifacts

Every release includes:

- **SLSA Build Level 3 Provenance**: Verifiable build attestations
- **SBOM**: Software Bill of Materials (SPDX format)
- **Sigstore Signatures**: Keyless signing via Fulcio + Rekor
- **Checksums**: SHA256 checksums for all binaries

## Quality Gates

All releases must pass:

- **Unit tests**: With race detector enabled
- **Linting**: golangci-lint + yamllint
- **License headers**: All source files verified
- **Security scan**: Trivy vulnerability scan

## Verification

### Verify Container Attestations

```bash
# Get latest release tag
export TAG=$(curl -s https://api.github.com/repos/NVIDIA/eidos/releases/latest | jq -r '.tag_name')

# Verify with GitHub CLI (recommended)
gh attestation verify oci://ghcr.io/nvidia/eidos:${TAG} --owner nvidia
gh attestation verify oci://ghcr.io/nvidia/eidosd:${TAG} --owner nvidia

# Verify with Cosign
cosign verify-attestation \
  --type spdxjson \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'https://github.com/NVIDIA/eidos/.github/workflows/.*' \
  ghcr.io/nvidia/eidos:${TAG}
```

### Verify Binary Checksums

```bash
# Download checksums file from GitHub Release
curl -sL "https://github.com/NVIDIA/eidos/releases/download/${TAG}/eidos_checksums.txt" -o checksums.txt

# Verify downloaded binary
sha256sum -c checksums.txt --ignore-missing
```

### Pull and Test Images

```bash
# Pull container images
docker pull ghcr.io/nvidia/eidos:${TAG}
docker pull ghcr.io/nvidia/eidosd:${TAG}

# Test CLI
docker run --rm ghcr.io/nvidia/eidos:${TAG} --version

# Test API server
docker run --rm -p 8080:8080 ghcr.io/nvidia/eidosd:${TAG} &
curl http://localhost:8080/health
```

## Version Management

- **Semantic versioning**: `vMAJOR.MINOR.PATCH`
- **Pre-releases**: `v1.2.3-rc1`, `v1.2.3-beta1` (automatically marked in GitHub)
- **Breaking changes**: Increment MAJOR version

## Demo Cloud Run Deployment

> **Note**: This is a **demonstration deployment** for testing and development purposes only. It is not a production service. Users should self-host the `eidosd` API server in their own infrastructure for production use. See [API Server Documentation](docs/architecture/api-server.md) for deployment guidance.

The `eidosd` API server demo is automatically deployed to Google Cloud Run on successful release:

- **Project**: `eidosx`
- **Region**: `us-west1`
- **Service**: `api`
- **Authentication**: Workload Identity Federation (keyless)

This demo deployment only occurs if the build step succeeds and serves as an example of how to deploy the API server.

## Troubleshooting

### Failed Release

1. Check **Actions** → **On Tag Release** for error logs
2. Common issues:
   - Tests failing: Fix and create new tag
   - Lint errors: Run `make lint` locally first
   - Image push failures: Check GHCR permissions

### Rebuild Existing Release

Use manual workflow trigger with the existing tag. No need to delete and recreate tags.

### Rollback Demo Deployment

To rollback the demo Cloud Run deployment (maintainers only):

```bash
# List revisions
gcloud run revisions list --service=api --region=us-west1 --project=eidosx

# Rollback to previous revision
gcloud run services update-traffic api \
  --to-revisions=api-PREVIOUS_REVISION=100 \
  --region=us-west1 \
  --project=eidosx
```

## Emergency Hotfix Procedure

For urgent fixes:

1. **Fix in main first**:
   ```bash
   git checkout main
   git checkout -b fix/critical-issue
   # Apply fix, create PR to main, merge
   ```

2. **Create hotfix release**:
   ```bash
   git checkout main
   git pull origin main
   git tag v1.2.4
   git push origin v1.2.4  # Triggers automatic release
   ```

3. **For patching older releases** (rare):
   ```bash
   git checkout v1.2.3
   git checkout -b hotfix/v1.2.4
   git cherry-pick <commit-hash-from-main>
   git tag v1.2.4
   git push origin v1.2.4
   ```

## Release Checklist

Before creating a release tag:

- [ ] All CI checks pass on main (`make qualify`)
- [ ] CHANGELOG or release notes prepared (auto-generated from commits)
- [ ] Breaking changes documented
- [ ] Version follows semantic versioning
- [ ] No uncommitted changes

After release:

- [ ] GitHub Release created with changelog
- [ ] Container images available in GHCR
- [ ] Attestations verifiable
- [ ] Demo Cloud Run deployment successful (optional)
- [ ] Announce release (if applicable)
