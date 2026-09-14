# Argo CD 배포 경로

`bootstrap/install/`은 Argo CD 자체를 클러스터에 최초 설치하는 파일이다. 반면 이 디렉터리는
Argo CD가 어떤 환경의 어떤 Kustomize overlay를 동기화할지 정의한다.

```text
argocd/
├── project.yaml                         배포 권한 범위(AppProject)
├── root-app-kind-dev.yaml               Kind app-of-apps 진입점
└── applications/kind-dev/               Kind Child Application
    ├── ingress-nginx.yaml
    ├── platform.yaml
    ├── identity.yaml
    ├── community.yaml
    ├── travel.yaml
    └── maps.yaml
```

Child Application은 `k8s/overlays/kind-dev/...`의 최종 환경 overlay만 가리킨다.
`base`를 직접 가리키지 않으므로, Argo CD가 환경값이 누락된 중간 리소스를 배포하지 않는다.

## dev EKS MSA (SCRUM-153)

`project-dev-eks.yaml`과 `root-app-dev-eks.yaml`은 dev EKS에서 MSA overlay를 관리하는
별도 app-of-apps 진입점이다. `platform-dev-eks`는 AWS Load Balancer Controller,
metrics-server, Cluster Autoscaler를 먼저 적용하고, `workload-dev-eks`는 monitoring,
네 서비스와 ALB Ingress를 적용한다.

두 child Application은 처음에는 자동 sync를 사용하지 않는다. EKS의 Secret, ECR image pull
권한, RDS/Redis 연결을 확인한 후 담당자가 Argo CD UI 또는 CLI로 수동 sync한다. 정상 배포가
확인된 뒤에만 자동 sync를 별도 변경으로 활성화한다.

EKS bootstrap 순서:

```bash
# Argo CD가 설치된 dev EKS 클러스터에서 실행
kubectl apply -f argocd/project-dev-eks.yaml
kubectl apply -f argocd/root-app-dev-eks.yaml
```

private `travel-gitops` 레포를 읽을 수 있도록 Argo CD의 repository credential을 먼저
등록해야 한다. 이 read credential은 서비스 CI가 GitOps PR을 만드는 GitHub App 권한과 별개다.

## SCRUM-128 경로 전환

SCRUM-128 이전에 설치된 root Application은 이전 경로
`clusters/kind-dev/applications`를 가리킨다. PR이 `develop`에 머지된 뒤, 클러스터에
접근 가능한 담당자가 한 번 실행한다.

```bash
git switch develop
git pull --ff-only
./scripts/migrate-argocd-layout.sh
kubectl -n argocd get applications
```

새 클러스터에는 전환 스크립트가 필요 없다. `./scripts/argocd-bootstrap.sh`가 처음부터
`argocd/root-app-kind-dev.yaml`을 적용한다.
