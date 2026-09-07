# dev-eks central metrics bundle

이 base는 Kubernetes API discovery, Backend `/actuator/prometheus`,
kube-state-metrics를 수집해 private Monitoring EC2 Prometheus의
`/api/v1/write`로 remote-write한다.

- 중앙 Alloy에는 로그 pipeline이나 node log filesystem mount가 없다.
- Backend ECS JSON 파일은 `k8s/base/backend`의 Pod-local Alloy sidecar가 읽는다.
- Alloy와 kube-state-metrics는 AWS IAM 권한이 없는 ServiceAccount를 사용한다.
- `k8s/overlays/dev-eks`가 Backend base와 이 monitoring base를 함께 조합한다.

이미지는 모두 공식 upstream tag와 immutable digest를 함께 사용한다. 현재 KSM은
`v2.19.1`(Kubernetes 1.35 client-go `v0.35.4`)으로 고정되어 있고, Metrics Server
`v0.8.1`, Cluster Autoscaler `v1.35.0`, AWS Load Balancer Controller `v3.3.0`의
검증된 tag+digest는 실행 evidence의 platform version lock에서 관리한다.
