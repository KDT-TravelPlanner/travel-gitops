# SCRUM-81 — Kubernetes 매니페스트 구조

- `base/backend/<service>-service`: Kind/EKS 공통 Deployment·Service.
- `base/backend/monolith`: 이전 EKS backend와 sidecar 구성 보존.
- `base/platform`: Kind namespace, `base/platform-eks`: EKS controller/autoscaler/metrics-server.
- `base/monitoring`: 노드별 Alloy DaemonSet, 단일 alloy-common, kube-state-metrics 및 RBAC.
- `overlays/kind-dev`: 기존 로컬 서비스·PostgreSQL·Redis·nginx. 변경하지 않는다.
- `overlays/dev-eks/{platform,workload}`: 기본 EKS MSA. workload 아래 서비스별 prod 설정·image digest·Secret 참조·HPA·sidecar.
- `overlays/dev-eks-monolith`: 기존 EKS 모놀리스와 전용 load-test.

EKS에서는 RDS·ElastiCache를 사용한다. 앱 4개와 travel-common 라이브러리를 구분한다.
Argo CD의 EKS 설정은 이후 범위다. 현재 S3 bundle → SSM Bastion → Kustomize로 배포한다.
상세 실행 계약: `scripts/eks/README.md`.
