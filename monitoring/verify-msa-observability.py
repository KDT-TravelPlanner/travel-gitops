#!/usr/bin/env python3
"""SCRUM-81: verify all four services, fresh metrics and low-cardinality logs.
Run on the private bastion with access to Monitoring EC2. Fixture mode is offline.
Readiness and data/AWS checks remain separate deployment acceptance checks.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time
import sys

spec = importlib.util.spec_from_file_location(
    "legacy", Path(__file__).with_name("verify-eks-observability-smoke.py")
)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
SERVICES = ("identity", "community", "maps", "travel")


def verify_service(service, prom, logs, age):
    now = time.time()
    rows = prom.get("data", {}).get("result", [])
    minimum = 1 if service == "identity" else 2
    if prom.get("status") != "success" or len(rows) < minimum:
        raise ValueError(f"{service}: at least {minimum} app metric targets required")
    seen = set()
    for row in rows:
        labels = row.get("metric", {})
        stamp, value = row.get("value", [None, None])
        pod = labels.get("pod")
        if (
            labels.get("app") != service + "-service"
            or labels.get("environment") != "dev-eks"
            or labels.get("platform") != "eks"
            or not pod
            or pod in seen
        ):
            raise ValueError(f"{service}: missing or duplicate metric target")
        seen.add(pod)
        if float(value) != 1 or not 0 <= now - float(stamp) <= age:
            raise ValueError(f"{service}: stale or unhealthy target")
    streams = logs.get("data", {}).get("result", [])
    if logs.get("status") != "success" or not streams:
        raise ValueError(f"{service}: logs missing")
    for stream in streams:
        labels = stream.get("stream", {})
        if (
            set(labels) - legacy.SAFE_LOKI_LABELS
            or labels.get("service") != service + "-service"
            or labels.get("environment") != "dev-eks"
        ):
            raise ValueError(f"{service}: unexpected log labels")
        values = stream.get("values", [])
        if not values or not any(0 <= now - int(v[0]) / 1e9 <= age for v in values):
            raise ValueError(f"{service}: fresh logs missing")
    return {
        "status": "passed",
        "metric_targets": len(seen),
        "log_streams": len(streams),
    }


def verify(fixture=None, prometheus_url=None, loki_url=None, age=180):
    checks = {}
    for service in SERVICES:
        if fixture is not None:
            data = fixture[service]
            prom = data["prometheus"]
            logs = data["loki"]
        else:
            prom = legacy._http_json(
                prometheus_url,
                "/api/v1/query",
                {
                    "query": f'up{{app="{service}-service",environment="dev-eks",platform="eks"}}'
                },
            )["payload"]
            logs = legacy._http_json(
                loki_url,
                "/loki/api/v1/query_range",
                {
                    "query": f'{{service="{service}-service",environment="dev-eks"}}',
                    "start": str(int((time.time() - age) * 1e9)),
                    "end": str(int(time.time() * 1e9)),
                    "limit": "20",
                },
            )["payload"]
        checks[service] = verify_service(service, prom, logs, age)
    return {
        "schema_version": "eks-msa-observability/v1",
        "status": "passed",
        "checks": checks,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--fixture", type=Path)
    p.add_argument("--prometheus-url")
    p.add_argument("--loki-url")
    p.add_argument("--output", type=Path)
    p.add_argument("--max-age-seconds", type=int, default=180)
    a = p.parse_args()
    if a.max_age_seconds <= 0 or (
        not a.fixture and not (a.prometheus_url and a.loki_url)
    ):
        p.error("positive age and fixture or both monitoring URLs required")
    try:
        result = verify(
            json.loads(a.fixture.read_text()) if a.fixture else None,
            a.prometheus_url,
            a.loki_url,
            a.max_age_seconds,
        )
    except (ValueError, KeyError, TypeError, legacy.VerificationError):
        print(
            "MSA observability incomplete: missing, stale, duplicate or invalid evidence",
            file=sys.stderr,
        )
        return 1
    text = json.dumps(result, indent=2) + "\n"
    if a.output:
        a.output.write_text(text)
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
