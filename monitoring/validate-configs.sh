#!/usr/bin/env bash
# SCRUM-81: validate exact EKS configs without contacting AWS or Kubernetes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys,yaml
root,tmp=map(Path,sys.argv[1:])
for p in (root/'k8s/base/monitoring').glob('*configmap.yaml'):
    for key,value in yaml.safe_load(p.read_text()).get('data',{}).items():
        if key.endswith('.alloy'):(tmp/(p.stem+'.alloy')).write_text(value)
for p in (root/'k8s/overlays/dev-eks/workload').glob('*/config.alloy'):
    (tmp/(p.parent.name+'.alloy')).write_text(p.read_text())
PY
for config in "$tmp"/*.alloy; do
  docker run --rm -e NODE_NAME=validation-node -v "$tmp:/config:ro" grafana/alloy:v1.16.1 validate "/config/$(basename "$config")"
done
docker run --rm --entrypoint /bin/promtool -v "$root/monitoring/prometheus:/config:ro" prom/prometheus:v3.13.1 check config /config/prometheus.eks.yml
docker run --rm -v "$root/monitoring/loki:/config:ro" grafana/loki:3.7.2 -verify-config=true -config.file=/config/loki.prod.yml
python3 - "$root" "$tmp" <<'PY'
import json,re,sys,yaml
from pathlib import Path
root,tmp=map(Path,sys.argv[1:]); d=json.loads((root/'monitoring/grafana/dashboards/eks-msa.json').read_text()); rules=[]
for panel in d['panels']:
    if panel['datasource']['type']!='prometheus':continue
    for target in panel['targets']:
        q=target['expr'].replace('${service:regex}','identity|community|maps|travel').replace('$service','identity|community|maps|travel').replace('$pod','.*')
        rules.append({'record':'scrum81:panel_'+str(panel['id']),'expr':q})
(tmp/'rules.yml').write_text(yaml.safe_dump({'groups':[{'name':'scrum81-dashboard','rules':rules}]}))
PY
docker run --rm --entrypoint /bin/promtool -v "$tmp:/config:ro" prom/prometheus:v3.13.1 check rules /config/rules.yml
