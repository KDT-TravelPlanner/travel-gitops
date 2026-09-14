#!/usr/bin/env python3
"""Fail-closed, sanitized EKS data and observability smoke verifier.

Live mode reads only HTTP status/shape and a sanitized data-evidence contract.
Fixture mode is intentionally deterministic for local tests. Response bodies,
Secret values, tokens, URLs and log lines are never copied into the report.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin
from urllib.request import Request, urlopen


EXPECTED_ENVIRONMENT = "dev-eks"
EXPECTED_PLATFORM = "eks"
SAFE_LOKI_LABELS = {"service", "environment", "level"}
ALLOWED_FLYWAY_EVIDENCE_SOURCES = {"startup-log", "backend-readiness-jpa-validation"}
FORBIDDEN_LABEL_FRAGMENTS = (
    "userid",
    "travelid",
    "requestid",
    "token",
    "email",
    "url",
)
REQUIRED_DATA_FIELDS = (
    "secret_materialized",
    "private_dns_verified",
    "rds_available",
    "flyway_success",
    "redis_authenticated",
    "profile_image_identity",
)


class VerificationError(Exception):
    """A safe, operator-actionable verification failure."""


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be an object")
    return value


def _status_payload(response: dict[str, Any], label: str) -> tuple[int, dict[str, Any]]:
    status = response.get("status")
    if not isinstance(status, int):
        raise VerificationError(f"{label} response status is missing")
    payload = _mapping(response.get("payload"), f"{label} response payload")
    return status, payload


def _http_json(base_url: str, path: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    endpoint = urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    if params:
        endpoint = f"{endpoint}?{urlencode(params)}"
    request = Request(endpoint, headers={"Accept": "application/json"})
    try:
        with urlopen(request, timeout=10) as response:
            raw = response.read(2_000_000)
            payload = json.loads(raw.decode("utf-8"))
            return {"status": response.status, "payload": payload}
    except HTTPError as error:
        raise VerificationError(f"{path} returned HTTP {error.code}") from None
    except (URLError, TimeoutError, OSError, json.JSONDecodeError):
        raise VerificationError(f"{path} was unreachable or malformed") from None


def _load_fixture(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise VerificationError("fixture is unreadable or invalid JSON") from None
    return _mapping(value, "fixture")


def _read_data_evidence(value: Any) -> dict[str, Any]:
    data = _mapping(value, "data evidence")
    result: dict[str, Any] = {}
    for field in REQUIRED_DATA_FIELDS:
        if data.get(field) is not True:
            raise VerificationError(f"data evidence failed: {field}")
        result[field] = True
    source = data.get("flyway_evidence_source")
    if source is not None:
        if source not in ALLOWED_FLYWAY_EVIDENCE_SOURCES:
            raise VerificationError("data evidence has an unexpected Flyway evidence source")
        result["flyway_evidence_source"] = source
    return result


def _check_backend(response: dict[str, Any]) -> dict[str, Any]:
    status, payload = _status_payload(response, "Backend readiness")
    if status != 200 or payload.get("status") != "UP":
        raise VerificationError("Backend readiness is not UP")
    return {"http_status": status, "status": "UP"}


def _as_timestamp(value: Any, *, nanoseconds: bool = False) -> float:
    try:
        timestamp = float(value)
    except (TypeError, ValueError):
        raise VerificationError("observability timestamp is malformed") from None
    if nanoseconds:
        timestamp /= 1_000_000_000
    return timestamp


def _check_prometheus(response: dict[str, Any], max_age_seconds: int) -> dict[str, Any]:
    status, payload = _status_payload(response, "Prometheus query")
    data = _mapping(payload.get("data"), "Prometheus data")
    results = data.get("result")
    if status != 200 or payload.get("status") != "success" or not isinstance(results, list) or not results:
        raise VerificationError("Prometheus returned no successful dev-eks series")
    now = time.time()
    ages: list[float] = []
    for item in results:
        metric = _mapping(item.get("metric"), "Prometheus metric")
        if metric.get("environment") != EXPECTED_ENVIRONMENT or metric.get("platform") != EXPECTED_PLATFORM:
            raise VerificationError("Prometheus series has an unexpected environment/platform")
        value = item.get("value")
        if not isinstance(value, list) or len(value) < 2:
            raise VerificationError("Prometheus series has no instant value")
        age = now - _as_timestamp(value[0])
        if age < -30 or age > max_age_seconds:
            raise VerificationError("Prometheus series is stale")
        ages.append(age)
    return {
        "series_count": len(results),
        "max_age_seconds": round(max(ages), 3),
        "environment": EXPECTED_ENVIRONMENT,
        "platform": EXPECTED_PLATFORM,
    }


def _check_loki(response: dict[str, Any], max_age_seconds: int) -> dict[str, Any]:
    status, payload = _status_payload(response, "Loki query")
    data = _mapping(payload.get("data"), "Loki data")
    streams = data.get("result")
    if status != 200 or payload.get("status") != "success" or not isinstance(streams, list) or not streams:
        raise VerificationError("Loki returned no Backend stream")
    now = time.time()
    line_count = 0
    max_age = 0.0
    for stream in streams:
        stream_map = _mapping(stream, "Loki stream")
        labels = _mapping(stream_map.get("stream"), "Loki labels")
        if set(labels) - SAFE_LOKI_LABELS:
            raise VerificationError("Loki stream contains an unapproved label")
        if labels.get("service") != "travel-planner-backend" or labels.get("environment") != EXPECTED_ENVIRONMENT:
            raise VerificationError("Loki stream is not the dev-eks Backend stream")
        for label in labels:
            lowered = label.lower().replace("_", "")
            if any(fragment in lowered for fragment in FORBIDDEN_LABEL_FRAGMENTS):
                raise VerificationError("Loki stream contains a forbidden dynamic label")
        values = stream_map.get("values")
        if not isinstance(values, list) or not values:
            raise VerificationError("Loki stream contains no log entries")
        line_count += len(values)
        for entry in values:
            if not isinstance(entry, list) or not entry:
                raise VerificationError("Loki entry is malformed")
            age = now - _as_timestamp(entry[0], nanoseconds=True)
            if age < -30 or age > max_age_seconds:
                raise VerificationError("Loki entry is stale")
            max_age = max(max_age, age)
    return {
        "stream_count": len(streams),
        "line_count": line_count,
        "max_age_seconds": round(max_age, 3),
        "labels": sorted(SAFE_LOKI_LABELS),
    }


def verify(
    *,
    fixture: dict[str, Any] | None,
    backend_url: str | None,
    prometheus_url: str | None,
    loki_url: str | None,
    data_evidence: dict[str, Any] | None,
    max_age_seconds: int,
) -> dict[str, Any]:
    if fixture is None and not all((backend_url, prometheus_url, loki_url, data_evidence is not None)):
        raise VerificationError("live mode requires Backend, Prometheus, Loki and data evidence inputs")
    if fixture is not None:
        backend_response = _mapping(fixture.get("backend"), "fixture.backend")
        prometheus_response = _mapping(fixture.get("prometheus"), "fixture.prometheus")
        loki_response = _mapping(fixture.get("loki"), "fixture.loki")
        data_value = fixture.get("data")
    else:
        backend_response = _http_json(backend_url or "", "/actuator/health/readiness")
        prometheus_response = _http_json(
            prometheus_url or "",
            "/api/v1/query",
            {"query": 'up{environment="dev-eks",platform="eks"}'},
        )
        now_ns = str(int(time.time() * 1_000_000_000))
        loki_response = _http_json(
            loki_url or "",
            "/loki/api/v1/query_range",
            {
                "query": '{service="travel-planner-backend",environment="dev-eks"}',
                "start": str(int((time.time() - max_age_seconds) * 1_000_000_000)),
                "end": now_ns,
                "limit": "20",
                "direction": "backward",
            },
        )
        data_value = data_evidence
    checks = {
        "data": _read_data_evidence(data_value),
        "backend": _check_backend(backend_response),
        "prometheus": _check_prometheus(prometheus_response, max_age_seconds),
        "loki": _check_loki(loki_response, max_age_seconds),
    }
    return {
        "status": "passed",
        "environment": EXPECTED_ENVIRONMENT,
        "platform": EXPECTED_PLATFORM,
        "checked_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "max_age_seconds": max_age_seconds,
        "checks": checks,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, help="offline sanitized fixture JSON")
    parser.add_argument("--backend-url", help="Backend base URL in live mode")
    parser.add_argument("--prometheus-url", help="Prometheus base URL in live mode")
    parser.add_argument("--loki-url", help="Loki base URL in live mode")
    parser.add_argument("--data-evidence", type=Path, help="sanitized data/identity evidence JSON")
    parser.add_argument("--max-age-seconds", type=int, default=180)
    parser.add_argument("--output", type=Path, help="write the sanitized report here")
    args = parser.parse_args(argv)
    if args.max_age_seconds <= 0:
        parser.error("--max-age-seconds must be positive")
    if args.fixture and args.data_evidence:
        parser.error("--fixture already contains data evidence; do not combine it with --data-evidence")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        fixture = _load_fixture(args.fixture) if args.fixture else None
        data_evidence = _load_fixture(args.data_evidence) if args.data_evidence else None
        report = verify(
            fixture=fixture,
            backend_url=args.backend_url,
            prometheus_url=args.prometheus_url,
            loki_url=args.loki_url,
            data_evidence=data_evidence,
            max_age_seconds=args.max_age_seconds,
        )
    except VerificationError as error:
        print(f"EKS observability smoke failed: {error}", file=sys.stderr)
        return 1
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
