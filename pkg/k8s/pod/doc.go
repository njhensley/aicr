// Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
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

/*
Package pod provides shared utilities for Kubernetes Job and Pod operations.

This package consolidates common functionality used by both the snapshot agent
(pkg/k8s/agent) and validation agent (pkg/validator/agent):

  - Job lifecycle: WaitForJobCompletion
  - Pod logs: StreamLogs, GetPodLogs
  - Pod readiness: WaitForPodReady
  - ConfigMap URIs: ParseConfigMapURI

All functions use structured error handling (pkg/errors) and respect context
deadlines for proper timeout management.

Example usage:

	// Wait for job completion
	err := pod.WaitForJobCompletion(ctx, client, namespace, jobName, timeout)

	// Stream pod logs to writer
	err := pod.StreamLogs(ctx, client, namespace, podName, os.Stdout)

	// Get pod logs as string
	logs, err := pod.GetPodLogs(ctx, client, namespace, podName)
*/
package pod
