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

Terraform은 Kubernetes 워크로드를 직접 apply하지 않는다. SCRUM-81 이후 기본
`k8s/overlays/dev-eks`는 4개 MSA와 Alloy 관측 구성을 제공한다. 이전 모놀리스와
부하테스트는 `k8s/overlays/dev-eks-monolith`에 보존한다.

배포 계약 v2는 서비스별 ECR repository와 실제 Redis TLS endpoint를 포함한다.
`identity` ServiceAccount 전용 Pod Identity를 추가하며 기존 `backend` identity는
모놀리스 호환용으로 보존한다. 기본 노드는 2 x t3.large, 최대 4대다.
기존 실제 tfvars 값이 기본값을 덮어쓰므로 plan에서 용량 설정을 반드시 확인한다.

Argo CD는 이번 범위 밖이다. S3 bundle과 SSM Bastion의 staged runner로 배포한다.

ALB에서 Pod로 들어오는 TCP 8080(API), TCP 9091(readiness health check)은
`aws_vpc_security_group_ingress_rule.cluster_from_alb`가 EKS cluster SG에 허용한다.
출발지는 해당 ALB SG만 허용한다. Ingress의 backend SG 자동 관리는 끈 상태를 유지하고
Terraform이 이 규칙을 소유한다. ALB 송신 규칙만으로는 Pod에 도달할 수 없다.
이 규칙 수정만 적용할 때에는 새 Terraform plan/apply로 충분하며 Pod 재배포는 필요하지 않다.
적용 후 target health가 healthy인지, OAuth 시작 요청이 504 대신 정상 리다이렉트하는지 확인한다.

### SCRUM-81 SG 통신 경로 점검

| 시작 → 목적지 | 포트 | SG 허용 방식 |
|---|---|---|
| 인터넷 → ALB | TCP 80/443 | ALB public ingress |
| ALB → Pod | TCP 8080/9091 | ALB egress + cluster_from_alb ingress |
| Pod/노드/control plane 상호 | 서비스 8080, actuator 9091, DNS, kubelet/webhook 등 | EKS cluster SG self ingress + egress |
| Pod → RDS | TCP 5432 | cluster egress + database_cluster ingress |
| Pod → Redis | TCP 6379 | cluster egress + cache_cluster ingress |
| Alloy → Monitoring | TCP 9090/3100 | cluster egress + monitoring_prometheus/loki ingress |
| 배스천 → EKS API | TCP 443 | bastion HTTPS egress + cluster_from_bastion ingress |
| 배스천 → Monitoring 검증 API | TCP 9090/3100 | bastion_monitoring egress + monitoring_from_bastion ingress |
| 노드/Pod → 외부 API·ECR·S3 | TCP 443 | cluster egress + app subnet NAT 경로 |
| 배스천/Monitoring → AWS·이미지 registry | TCP 443 | 각 HTTPS egress + NAT 경로 |

배스천의 `verify-msa-observability.py` 실행에 필요한 9090/3100은 양쪽 SG에서 정확한
상대 SG만 허용한다. Grafana 3000은 Monitoring EC2의 loopback에만 바인딩하므로
SG를 열지 않고 해당 인스턴스로 SSM 포트 포워딩한다. 배스천의 DB/Redis 직접 연결은
현재 배포 절차에 필요하지 않아 열지 않는다. Secrets Manager 값 주입은 HTTPS로 수행한다.

SG는 stateful이므로 DB/Redis의 응답을 위해 별도 egress나 ephemeral port ingress를 추가하지 않는다.
위 표는 현재 default VPC CNI와 실제 ENI가 cluster SG를 사용하는 구조를 기준으로 한다.
SG for Pods나 별도 node SG로 전환할 때는 target SG를 다시 검토해야 한다.
네트워크 허용은 IAM·TLS·OAuth 설정·API 기능 성공을 증명하지 않으므로 적용 후 별도 검증한다.
실제 4개 이미지 digest는 팀원 CI/CD 검증 후 제공해야 한다.
입력·단계·검증·롤백은 `scripts/eks/README.md`에 정리되어 있다.
설정 테스트 통과는 EKS 실배포 성공을 뜻하지 않는다.
