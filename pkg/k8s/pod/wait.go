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

package pod

import (
	"context"
	"time"

	"github.com/NVIDIA/eidos/pkg/errors"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
)

// WaitForPodReady waits for a pod to become ready within the specified timeout.
// Returns nil if pod becomes ready, error if timeout or pod fails.
func WaitForPodReady(ctx context.Context, client kubernetes.Interface, namespace, name string, timeout time.Duration) error {
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	return wait.PollUntilContextCancel(timeoutCtx, 500*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		pod, err := client.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return false, errors.Wrap(errors.ErrCodeInternal, "failed to get pod", err)
		}

		// Check if pod is ready
		for _, condition := range pod.Status.Conditions {
			if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
				return true, nil
			}
		}

		// Check for failed state
		if pod.Status.Phase == corev1.PodFailed {
			return false, errors.NewWithContext(errors.ErrCodeInternal, "pod failed", map[string]interface{}{
				"namespace": namespace,
				"name":      name,
				"reason":    pod.Status.Reason,
				"message":   pod.Status.Message,
			})
		}

		return false, nil
	})
}
