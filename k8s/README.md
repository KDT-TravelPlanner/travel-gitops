# Kubernetes 매니페스트 구조

이 레포는 Kustomize의 `base`와 `overlays`를 분리한다.

```text
k8s/
├── base/
│   ├── backend/<service>/    환경 공통 Deployment·Service
│   └── platform/             환경 공통 Namespace
└── overlays/<environment>/
    ├── backend/<service>/    환경별 ConfigMap·이미지·연결 주소
    ├── platform/             환경별 DB·Redis·Ingress
    └── ingress-nginx/        해당 환경의 ingress controller
```

## 이 구조를 선택한 이유

- **변경 위치가 명확하다.** 서비스 Pod는 `backend`, DB·Ingress·Namespace 같은 공용
  기반은 `platform`, 이후 Alloy·Loki·Prometheus·Grafana는 `monitoring`으로 분리한다.
- **환경을 복제하지 않는다.** Kind와 EKS가 공유하는 Deployment·Service는 `base`에 한 번만
  정의한다. DB 주소, Secret 연결, 이미지처럼 달라지는 값만 각 overlay에서 덮어쓴다.
- **Argo CD의 추적 경로가 분명하다.** `argocd/applications/<environment>/`의 Application은
  최종 배포 단위인 `k8s/overlays/<environment>/...`만 가리킨다.

현재는 `kind-dev`만 제공한다. EKS 전환 시 같은 규칙으로
`k8s/overlays/eks-dev/{backend,platform,monitoring}`을 추가한다. Kind의 PostgreSQL·Redis
매니페스트는 EKS overlay로 복사하지 않으며, EKS에서는 RDS·ElastiCache 연결 설정으로 대체한다.
