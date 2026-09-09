# SCRUM-81 — EKS monolith compatibility overlay

이 디렉터리는 기존 EKS 모놀리스와 SCRUM-80 부하테스트를 보존하는
호환용 aggregate 경로다. 기본 EKS MSA 경로는 `../dev-eks`이며, 이 경로는
그와 별도로 `platform/`과 `workload/`를 소유한다. 두 단계는 같은 Kustomize
object를 중복 소유하지 않는다.

## 로컬 렌더

```bash
kubectl kustomize k8s/overlays/dev-eks-monolith
```

`workload/backend-image.patch.yaml`의 action-time image sentinel과
`workload/backend-configmap.patch.yaml`의 profile-image/frontend sentinel은 실제
모놀리스 rollout 전에 승인된 Terraform/ECR 출력으로 교체한다. `backend-secret`은
AWS Secrets Manager에서 외부 bootstrap하며 Git/Argo CD가 소유하지 않는다.

## S3 검증 스냅샷

Argo CD가 설치되기 전에는 dev-eks Terraform이 이 overlay와 두 base를
Monitoring EC2의 전용 S3 버킷에 source snapshot으로 업로드할 수 있다. 자동화의
`prepare` stage가 이 private snapshot, non-secret action-values, runtime contract와
render hash를 같은 run prefix로 묶고, resume 시 bundle/values/render hash를 다시
검증한다. 실행자는 업로드된 스냅샷을 `kubectl diff -k`로 확인하고
`APPLY KUBERNETES <full-render-sha256>` 승인을 통과한 뒤에만 적용한다. `dry-run`은
이 S3/SSM/Kubernetes 경계를 호출하지 않는 local structural check다.
