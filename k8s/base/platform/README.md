# dev-eks platform base

이 base는 EKS 1.35의 Pod/node autoscaling에 필요한 Metrics Server와 Cluster
Autoscaler를 제공한다. 두 ServiceAccount는 EKS Pod Identity association이
Terraform에서 부여되므로 Git에는 annotation이나 credential을 두지 않는다.

- Metrics Server `v0.8.1`은 HPA의 `metrics.k8s.io` API를 제공한다.
- Cluster Autoscaler `v1.35.0`은 `k8s.io/cluster-autoscaler/*` 태그가 붙은
  dev-eks managed node group만 발견한다.
- Backend HPA와 hostname topology spread는 `k8s/base/backend`에 선언되어
  overlay에서 함께 렌더링된다.
