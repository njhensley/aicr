// Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package defaults

// Container images used by AICR validators for short-lived probe Pods
// (per-node host-state checks, DRA isolation smoke tests, autoscaling
// triggers, NCCL preflights, etc). Centralized so bumping a pin is a
// one-file change and every probe-style validator reuses a single,
// auditable image reference.
//
// Not load-time overridable: callers that need runtime override (airgapped
// registries, fork-specific pins) should read an environment variable at
// the call site and fall back to this value — the same pattern
// pkg/validator/catalog uses for AICR_VALIDATOR_IMAGE_REGISTRY.
const (
	// ProbeImage is the lightweight multi-arch Linux toolbox used by
	// validator probe Pods. Must be publicly pullable, support linux/amd64
	// and linux/arm64, and provide the standard UNIX utilities (/bin/sh,
	// grep, ls, sleep). busybox satisfies all of these in ~2 MB.
	ProbeImage = "busybox:1.37"
)
