import importlib.util
from pathlib import Path
import unittest
import time
import copy

spec = importlib.util.spec_from_file_location(
    "msa", Path(__file__).resolve().parents[1] / "verify-msa-observability.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    now = time.time()
    return {
        s: {
            "prometheus": {
                "status": "success",
                "data": {
                    "result": [
                        {
                            "metric": {
                                "pod": s + "-" + str(i),
                                "app": s + "-service",
                                "environment": "dev-eks",
                                "platform": "eks",
                            },
                            "value": [now, "1"],
                        }
                        for i in range(2)
                    ]
                },
            },
            "loki": {
                "status": "success",
                "data": {
                    "result": [
                        {
                            "stream": {
                                "service": s + "-service",
                                "environment": "dev-eks",
                                "level": "INFO",
                            },
                            "values": [[str(int(now * 1e9)), "fixture"]],
                        }
                    ]
                },
            },
        }
        for s in m.SERVICES
    }


class Tests(unittest.TestCase):
    def test_all_services_pass(self):
        self.assertEqual(m.verify(fixture())["status"], "passed")

    def test_one_identity_target_passes_but_other_services_require_two(self):
        f = fixture()
        f["identity"]["prometheus"]["data"]["result"] = f["identity"]["prometheus"]["data"]["result"][:1]
        self.assertEqual(m.verify(f)["status"], "passed")
        for service in m.SERVICES:
            with self.subTest(service=service):
                bad = copy.deepcopy(f)
                bad[service]["prometheus"]["data"]["result"] = bad[service]["prometheus"]["data"]["result"][:0 if service == "identity" else 1]
                with self.assertRaises(ValueError):
                    m.verify(bad)

    def test_missing_stale_duplicate_and_unsafe_labels_fail(self):
        for mode in ["missing", "stale", "duplicate", "unsafe", "down", "empty_logs"]:
            with self.subTest(mode=mode):
                f = fixture()
                x = f["maps"]
                if mode == "missing":
                    x["prometheus"]["data"]["result"] = []
                if mode == "stale":
                    x["prometheus"]["data"]["result"][0]["value"][0] -= 1000
                if mode == "duplicate":
                    x["prometheus"]["data"]["result"][1] = copy.deepcopy(
                        x["prometheus"]["data"]["result"][0]
                    )
                if mode == "unsafe":
                    x["loki"]["data"]["result"][0]["stream"]["userId"] = "fixture"
                if mode == "down":
                    x["prometheus"]["data"]["result"][0]["value"][1] = "0"
                if mode == "empty_logs":
                    x["loki"]["data"]["result"] = []
                with self.assertRaises(ValueError):
                    m.verify(f)
