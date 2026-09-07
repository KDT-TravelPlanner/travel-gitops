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
