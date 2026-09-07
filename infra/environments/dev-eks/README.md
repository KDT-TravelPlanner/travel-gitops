# SCRUM-127 — dev-eks 이관 및 검증

원본 `KDT_TravelDiary/infra/environments/dev-eks`의 Terraform, 변수, 출력, provider lock,
Bastion template과 mock 테스트를 복제했다. `main.tf`의 원본 리소스 주소와 동작을 유지했다.
참조 모듈 `eks_cluster`, `backend_data`, `monitoring_ec2` 및 Kubernetes/monitoring 파일도
이 저장소 안에 있어 원본 저장소에 대한 symlink나 상대 경로 의존성이 없다.

## State 전제

- backend: 기존 `dev-eks/terraform.tfstate`
- persistent remote state: 기존 `dev/terraform.tfstate`
- `dev-runtime`, `dev-load-test`의 state 조회가 성공하고 관리 리소스가 0인지 확인한다.
  조회 실패를 빈 state로 간주하지 않는다. 동일 app route의 중복 소유를 허용하지 않는다.
- 실제 계정 ID, EKS 버전, Pod Identity add-on 호환성은 plan 시점에 조회한다.

## 실행

```bash
export AWS_PROFILE=kdt-travel-terraform
terraform -chdir=infra/environments/dev-eks init -reconfigure -input=false -backend-config=backend.hcl
terraform -chdir=infra/environments/dev-eks validate
terraform -chdir=infra/environments/dev-eks test
terraform -chdir=infra/environments/dev-eks plan -input=false -out=dev-eks.tfplan
```

검토 대상은 private EKS/node group, NAT/routes, RDS/Redis, Pod Identity 역할,
SSM bastion, Monitoring EC2, private Route53, S3 source snapshot이다.
GitHub Actions용 OIDC는 persistent dev 소유이며, 이 root가 생성하는 OIDC는 EKS IRSA용이다.

Terraform은 Kubernetes 워크로드를 직접 apply하지 않는다. `k8s/overlays/dev-eks`는
원본 backend baseline snapshot으로, 기존 MSA `apps/`/kind GitOps 배포를 대체하지 않는다.
Bastion에 올리는 `bootstrap-backend-secret.sh`, `render-action-time.py`,
`run-dev-eks-deployment.sh` 3개는 포함되어 있다. 원본 호스트의 전체 실험·복구·폐기
오케스트레이터는 이번 Terraform 이관 범위에 포함하지 않았다.

실제 워크로드 배포에는 image digest, action-time 값, Secret bootstrap, private EKS 접근과
SSM 실행이 추가로 필요하다. 이 작업에서는 Terraform apply/Kubernetes apply를 실행하지 않는다.

[EKS 버전 지원 공식 문서](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
