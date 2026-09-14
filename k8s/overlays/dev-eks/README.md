# SCRUM-81 — EKS MSA

기본 EKS workload는 identity/community/maps/travel 4개 서비스(identity 1, 나머지 각 2 replica)와
Pod별 Alloy 로그 sidecar, 노드별 Alloy 메트릭 DaemonSet, 단일 공통 메트릭 수집기를 포함한다.
Argo CD는 사용하지 않는다. S3 source bundle과 SSM Bastion staged runner를 사용한다.

서비스별 실제 ECR digest는 CI/CD 완료 후 `scripts/eks/msa-values.example.json`에 입력한다.
예제의 placeholder는 배포할 수 없다. 초기 설정 검증은 `scripts/eks/tests`의 합성 fixture로 수행한다.
앱 CPU request는 각각 250m, memory request는 identity/maps 512Mi, travel 896Mi, community 1Gi다.
sidecar는 50m/64Mi이며 초기 총 7 Pod의 앱+sidecar 요청은 2100m/5824Mi이다.
HPA는 identity 1–4, 나머지 2–4이고 CPU target 60%를 유지한다.
2026-09-08 로컬 캠페인에 따른 예약량 후보이며 memory limit 1Gi/CPU limit 1은 유지한다.
community의 관측 최대 951.8MiB는 limit에 가까우므로 장시간 heap/native 메모리 검증이 필요하다.
기본 노드 2 x t3.large (각 2 vCPU/8GiB), 최대 4대이며 시스템 Pod와 rollout 여유를 별도 확인해야 한다.
실제 기존 terraform.tfvars의 node_instance_types는 기본값보다 우선하므로 plan 전에 확인한다.

기존 모놀리스 및 SCRUM-80 부하테스트는 `../dev-eks-monolith`에 보존한다.
상세 실행 및 롤백 계약은 `scripts/eks/README.md`를 참조한다.

## SCRUM-81 — CPU HPA 후속 검증 판단 (2026-09-09)

현재 목표 60%는 유지한다. 로컬 재실험은 후보를 좁히는 데 유용하지만 최적값 확정에는 부족하다.
앞선 느린 Maps 의존성 시험에서 travel Hikari pool이 Pod별 10/10, pending 최대 190에 도달했다.
외부 I/O를 포함하는 DB 트랜잭션과 내부 location cache 경로를 먼저 개선·검증한 뒤 임계값을 비교한다.

- 같은 이미지·seed·mock·CPU request 250m·limit 1·memory 설정·시작 Pod 1/2/2/2를 고정한다.
- 제안 후보는 CPU 40/50/60%(각 100/125/150m). 목표값만 바꾸고 순서를 교차해 조건별 3회 비교한다.
- 점진 stress와 spike에서 요청률/오류/p95/p99/drop, CPU throttling, Hikari pending, HPA desired/current를 함께 측정한다.
- 임계값 초과 관측→HPA desired 증가→Pod 생성→Ready→첫 성공/안정 응답을 분리한다. 관측보다 먼저 생성된 경우 반응 시간을 추측하지 않는다.
- Pod 증가가 없으면 해당 부하에서 임계값 차이를 비교할 정보가 부족한 것으로 기록한다.
- SLO를 통과하는 후보끼리 Pod-seconds, 증가 시점과 반복 증감 횟수를 비교한다. 안정 응답 조건은 동일하게 유지한다.
- 실제 HPA max=4와 Alloy sidecar를 넣으면 로컬 메모리 예산을 다시 확인한다. max=2 축소 시험은 별도 조건으로 표시한다.

로컬 ARM64/14 CPU, 호스트 swap, mock 외부 API, 기존 시험의 Alloy 부재는 EKS와 차이가 있다.
최종 후보는 t3.large EKS에서 app/Alloy, CPU credits, allocatable, 서비스 지연과 기동 시간을 포함해 확인한다.
지금 전체 부하를 반복하기보다 병목 개선→로컬 후보 비교→EKS 최종 검증 순서로 진행한다.
이번 설정 변경에서는 부하 재실험이나 클러스터 적용을 수행하지 않는다.

HPA는 request 대비 CPU 사용률과 준비 상태·누락 metric을 함께 처리하므로 Ready 15–16초만으로 임계값을 산출하지 않는다.
[Kubernetes HPA 공식 문서](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
