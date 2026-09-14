# SCRUM-81 — EKS 메트릭 수집

- Alloy DaemonSet은 NODE_NAME 기준 해당 노드의 annotated actuator Pod와 kubelet만 수집한다.
- alloy-common Deployment는 replica=1/Recreate로 kube-state-metrics를 단일 수집한다.
- 두 수집기는 private Monitoring EC2 Prometheus `/api/v1/write`로 보낸다.
- 로그는 각 앱 Pod의 Alloy sidecar가 ECS JSON 파일을 읽어 Monitoring EC2 Loki에 전달한다.
  MSA sidecar 설정은 `overlays/dev-eks/workload/<service>/config.alloy`에 있다.
- 서비스 메트릭은 app/pod/environment/platform, 로그는 service/environment/level로 구분한다.
- 수집기에는 AWS IAM 권한이 없으며 노드별 수집기만 Kubernetes API용 ServiceAccount token을 사용한다.
- `monitoring/validate-configs.sh`와 `monitoring/tests`에서 구문·관측 실패 조건을 검사한다.

원본 `KDT_TravelDiary`의 공식 tag+digest, 볼륨 권한 및 private Monitoring EC2 연결을 유지한다.
실제 수집 도착 여부는 EKS 배포 후 `monitoring/verify-msa-observability.py`로 별도 확인한다.
