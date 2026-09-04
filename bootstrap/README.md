# bootstrap/

Kind 클러스터에 **Argo CD** 를 올리고 travel-planner 스택을 GitOps 로 동기화한다.

```
bootstrap/
├── install/
│   ├── namespace.yaml
│   └── kustomization.yaml     Argo CD v3.5.2 (cluster-install) + server.insecure 패치
├── project.yaml               AppProject: travel-planner-kind-dev
└── root-app.yaml              Application(app-of-apps) → clusters/kind-dev/applications/
```

`clusters/kind-dev/applications/` 에 실제 Application 5개:
`platform`(wave -1: namespace/postgres/redis) + `identity`/`community`/`travel`/`maps`(wave 0).
전부 `automated` sync (`prune` + `selfHeal`).

## 설치

```bash
# 사전: kind 클러스터 + 이미지 빌드
kind create cluster --config clusters/kind-dev/kind-config.yaml
./scripts/build-images.sh
cp secrets/*.dev.env.example ...  # 값 채우기 (create-secrets.sh 가 참조)

# Argo CD 설치 + 동기화
./scripts/argocd-bootstrap.sh
```

내부적으로: 이미지 kind load → Secret 5개 생성(Argo 밖) → `kubectl apply -k bootstrap/install`
→ `project.yaml` + `root-app.yaml` apply → Argo 가 나머지를 sync.

## 확인 / 접속

```bash
kubectl -n argocd get applications          # 전부 Synced / Healthy
kubectl -n argocd port-forward svc/argocd-server 8081:80 &
# http://localhost:8081  (admin / 아래 비밀번호)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## private 레포 자격증명

`travel-gitops` 가 private 이면 Argo CD 가 pull 하도록 등록해야 한다:

```bash
argocd repo add https://github.com/protove/travel-gitops.git \
  --username <github-user> --password <PAT(repo:read)>
```

또는 `argocd` 네임스페이스에 아래 형태의 Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: travel-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/protove/travel-gitops.git
  username: <github-user>
  password: <PAT>
```

## 아직 안 하는 것

- **이미지 레지스트리 push**: 지금은 `kind load` 수동. 레지스트리(ECR) 확정 후
  CI 가 push → Argo 가 이미지 태그 변경 감지하도록 전환 예정.
- **ingress-nginx**: `kubectl port-forward` 로 충분. 추후 `platform/` 에 추가.
- Argo CD 자체를 Argo 가 관리(self-managed)하는 구성은 하지 않음.

## setup.sh 와의 관계

`scripts/setup.sh` = Argo 없이 `kubectl apply -k` 로 직접 배포하는 빠른 경로(로컬 테스트용).
`scripts/argocd-bootstrap.sh` = GitOps 경로. 둘 다 같은 매니페스트(`clusters/kind-dev/platform`,
`apps/*/overlays/kind-dev`)를 배포하므로 한 클러스터에 **동시에** 쓰지는 않는다.
