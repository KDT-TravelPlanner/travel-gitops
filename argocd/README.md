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

`dev-eks/project.yaml`과 `dev-eks/root-app.yaml`은 dev EKS에서 MSA overlay를 관리하는
별도 app-of-apps 진입점이다. `platform-dev-eks`는 AWS Load Balancer Controller,
metrics-server, Cluster Autoscaler를 먼저 적용하고, `workload-dev-eks`는 monitoring,
네 서비스와 ALB Ingress를 적용한다.

두 child Application은 처음에는 자동 sync를 사용하지 않는다. EKS의 Secret, ECR image pull
권한, RDS/Redis 연결을 확인한 후 담당자가 Argo CD UI 또는 CLI로 수동 sync한다. 정상 배포가
확인된 뒤에만 자동 sync를 별도 변경으로 활성화한다.

### 값 주입 방식 (Bastion runner와의 차이)

Bastion runner는 배포 시점에 `render-action-time.py`로 `__ACTION_TIME_*__`를 치환하지만,
Argo CD는 Git의 kustomize build 결과를 치환 없이 적용한다. 따라서 dev-eks overlay의
placeholder는 **실제 값으로 Git에 커밋**한다. 대상 값은 VPC/subnet/SG/ACM ARN/Redis endpoint/
origin/bucket 같은 비밀이 아닌 식별자뿐이며, Secret 값은 계속 Secrets Manager → `<service>-secret`
경로를 사용한다. 이미지 digest는 `update-gitops.yml`이 만드는 CI PR이 채운다.

```bash
terraform -chdir=infra/environments/dev-eks output -json > /tmp/dev-eks-outputs.json
python3 scripts/eks/fill-gitops-values.py \
  --terraform-output /tmp/dev-eks-outputs.json \
  --backend-hostname api.kdt-travelplanner.protove.net \
  --frontend-origin https://kdt-travelplanner.protove.net
python3 scripts/eks/fill-gitops-values.py --check   # placeholder 0개 확인
```

환경을 destroy 후 재생성하면 dev-eks state 소유인 ALB SG와 Redis endpoint만 바뀌므로
위 명령을 다시 실행해 PR을 올린다. VPC/subnet/bucket은 persistent `dev` state 소유라 유지된다.

### EKS bootstrap 순서

1. `scripts/eks/deploy-dev-eks-msa.py apply --through-stage platform`으로 클러스터, Secret,
   platform 컨트롤러(ALB Controller webhook TLS Secret 포함)까지 올린다. workload는 runner로
   올리지 않고 Argo CD가 담당한다. runner와 Argo CD가 같은 리소스를 동시에 apply하지 않는다.
2. 위 값 주입 PR을 main에 머지한다.
3. Bastion(SSM)에서 Argo CD를 설치하고 private 레포 read credential을 등록한다.

```bash
kubectl apply --server-side --force-conflicts -k bootstrap/install-eks
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: travel-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/KDT-TravelPlanner/travel-gitops.git
  username: <github-user>
  password: <PAT(repo:read) 또는 GitHub App token>
YAML
kubectl apply -f argocd/dev-eks/project.yaml
kubectl apply -f argocd/dev-eks/root-app.yaml
```

4. root → `platform-dev-eks` → `workload-dev-eks` 순으로 수동 sync한다. platform은 runner가
   올린 리소스를 adopt하므로 diff가 0이어야 한다.
5. API smoke 통과 후 별도 PR로 `workload-dev-eks`에 automated(prune, selfHeal)를 켠다.
   `ignoreDifferences: /spec/replicas`가 이미 있어 HPA와 충돌하지 않는다.

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
