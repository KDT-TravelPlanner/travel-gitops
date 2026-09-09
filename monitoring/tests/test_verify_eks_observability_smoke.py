"""Unit tests for the fail-closed EKS smoke verifier."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "monitoring" / "verify-eks-observability-smoke.py"
SPEC = importlib.util.spec_from_file_location("verify_eks_observability_smoke", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def fixture() -> dict:
    now = time.time()
    return {
        "backend": {"status": 200, "payload": {"status": "UP"}},
        "prometheus": {
            "status": 200,
            "payload": {
                "status": "success",
                "data": {
                    "result": [
                        {
                            "metric": {"environment": "dev-eks", "platform": "eks", "job": "backend"},
                            "value": [now, "1"],
                        }
                    ]
                },
            },
        },
        "loki": {
            "status": 200,
            "payload": {
                "status": "success",
                "data": {
                    "result": [
                        {
                            "stream": {
                                "service": "travel-planner-backend",
                                "environment": "dev-eks",
                                "level": "INFO",
                            },
                            "values": [[str(int(now * 1_000_000_000)), "sanitized-body"]],
                        }
                    ]
                },
            },
        },
        "data": {
            "secret_materialized": True,
            "private_dns_verified": True,
            "rds_available": True,
            "flyway_success": True,
            "redis_authenticated": True,
            "profile_image_identity": True,
        },
    }


class VerifyEksObservabilitySmokeTest(unittest.TestCase):
    def test_sanitized_fixture_passes_and_report_has_no_payload(self) -> None:
        payload = fixture()
        payload["loki"]["payload"]["data"]["result"][0]["values"][0][1] = "JWT_SECRET_VALUE_SHOULD_NOT_ESCAPE"
        report = MODULE.verify(
            fixture=payload,
            backend_url=None,
            prometheus_url=None,
            loki_url=None,
            data_evidence=None,
            max_age_seconds=180,
        )
        serialized = json.dumps(report)
        self.assertEqual(report["status"], "passed")
        self.assertNotIn("JWT_SECRET_VALUE_SHOULD_NOT_ESCAPE", serialized)
        self.assertNotIn("sanitized-body", serialized)

    def test_missing_data_evidence_fails_closed(self) -> None:
        payload = fixture()
        payload["data"]["redis_authenticated"] = False
        with self.assertRaises(MODULE.VerificationError):
            MODULE.verify(
                fixture=payload,
                backend_url=None,
                prometheus_url=None,
                loki_url=None,
                data_evidence=None,
                max_age_seconds=180,
            )

    def test_indirect_flyway_evidence_source_is_reported_without_payload(self) -> None:
        payload = fixture()
        payload["data"]["flyway_evidence_source"] = "backend-readiness-jpa-validation"
        report = MODULE.verify(
            fixture=payload,
            backend_url=None,
            prometheus_url=None,
            loki_url=None,
            data_evidence=None,
            max_age_seconds=180,
        )
        self.assertEqual(
            report["checks"]["data"]["flyway_evidence_source"],
            "backend-readiness-jpa-validation",
        )

    def test_unknown_flyway_evidence_source_fails_closed(self) -> None:
        payload = fixture()
        payload["data"]["flyway_evidence_source"] = "unverified"
        with self.assertRaises(MODULE.VerificationError):
            MODULE.verify(
                fixture=payload,
                backend_url=None,
                prometheus_url=None,
                loki_url=None,
                data_evidence=None,
                max_age_seconds=180,
            )

    def test_stale_prometheus_series_fails_closed(self) -> None:
        payload = fixture()
        payload["prometheus"]["payload"]["data"]["result"][0]["value"][0] = time.time() - 181
        with self.assertRaises(MODULE.VerificationError):
            MODULE.verify(
                fixture=payload,
                backend_url=None,
                prometheus_url=None,
                loki_url=None,
                data_evidence=None,
                max_age_seconds=180,
            )

    def test_dynamic_loki_label_fails_closed(self) -> None:
        payload = fixture()
        payload["loki"]["payload"]["data"]["result"][0]["stream"]["requestId"] = "dynamic"
        with self.assertRaises(MODULE.VerificationError):
            MODULE.verify(
                fixture=payload,
                backend_url=None,
                prometheus_url=None,
                loki_url=None,
                data_evidence=None,
                max_age_seconds=180,
            )

    def test_cli_fixture_writes_only_sanitized_report(self) -> None:
        payload = fixture()
        payload["loki"]["payload"]["data"]["result"][0]["values"][0][1] = "secret-body-sentinel"
        with tempfile.TemporaryDirectory() as directory:
            fixture_path = Path(directory) / "fixture.json"
            output_path = Path(directory) / "report.json"
            fixture_path.write_text(json.dumps(payload), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), "--fixture", str(fixture_path), "--output", str(output_path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("secret-body-sentinel", output_path.read_text(encoding="utf-8"))
            self.assertNotIn("secret-body-sentinel", result.stdout)

    def test_live_mode_requires_all_inputs(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.verify(
                fixture=None,
                backend_url=None,
                prometheus_url="http://prometheus",
                loki_url="http://loki",
                data_evidence=None,
                max_age_seconds=180,
            )


if __name__ == "__main__":
    unittest.main()
