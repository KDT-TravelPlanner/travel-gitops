#!/usr/bin/env python3
"""SCRUM-81 runtime boundary: private secrets, image architecture and rollout evidence.

All child output is captured. Secret payloads and registry credentials are never
printed or passed in process arguments. No dependencies beyond Python stdlib.
"""
import base64
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

SERVICES = ("identity", "community", "maps", "travel")
MIN_REPLICAS = {"identity": 1, "community": 2, "maps": 2, "travel": 2}
COMMON = ("SPRING_DATASOURCE_USERNAME", "SPRING_DATASOURCE_PASSWORD", "JWT_SECRET")
KEYS = {s: list(COMMON) for s in SERVICES}
KEYS["identity"] += [
    "SPRING_DATA_REDIS_PASSWORD",
    "GOOGLE_OAUTH_CLIENT_ID",
    "GOOGLE_OAUTH_CLIENT_SECRET",
    "NAVER_OAUTH_CLIENT_ID",
    "NAVER_OAUTH_CLIENT_SECRET",
]
KEYS["maps"] += ["SPRING_DATA_REDIS_PASSWORD", "GOOGLE_MAPS_API_KEY"]


def command(args, payload=None):
    result = subprocess.run(args, input=payload, capture_output=True)
    if result.returncode:
        raise ValueError(f"{args[0]} operation failed (details withheld)")
    return result.stdout


def aws(contract, *args):
    return json.loads(
        command(["aws", *args, "--region", contract["aws_region"], "--output", "json"])
    )


def secret_payloads(application, database, redis):
    values = dict(
        application,
        SPRING_DATASOURCE_USERNAME=database.get("username"),
        SPRING_DATASOURCE_PASSWORD=database.get("password"),
        SPRING_DATA_REDIS_PASSWORD=redis.get("password"),
    )
    result = []
    for service, keys in KEYS.items():
        if any(not isinstance(values.get(k), str) or not values[k] for k in keys):
            raise ValueError(f"Missing required secret key for {service}")
        result.append(
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {
                    "name": service + "-secret",
                    "namespace": "travel-planner",
                },
                "type": "Opaque",
                "data": {
                    k: base64.b64encode(values[k].encode()).decode() for k in keys
                },
            }
        )
    return result


def bootstrap(contract):
    def secret(field):
        response = aws(
            contract,
            "secretsmanager",
            "get-secret-value",
            "--secret-id",
            contract[field],
        )
        return json.loads(response["SecretString"])

    payloads = secret_payloads(
        secret("backend_application_secret_arn"),
        secret("database_master_secret_arn"),
        secret("redis_auth_secret_arn"),
    )
    for item in payloads:
        command(
            [
                "kubectl",
                "apply",
                "--server-side",
                "--field-manager=scrum81-secret-bootstrap",
                "-f",
                "-",
            ],
            json.dumps(item).encode(),
        )
    verify_secrets()


def verify_secrets():
    for service, keys in KEYS.items():
        result = json.loads(
            command(
                [
                    "kubectl",
                    "get",
                    "secret",
                    service + "-secret",
                    "-n",
                    "travel-planner",
                    "-o",
                    "json",
                ]
            )
        )
        if set(result.get("data", {})) != set(keys) or any(
            not result["data"][k] for k in keys
        ):
            raise ValueError(f"Secret key set differs: {service}")


def inspect_images(contract, values):
    repos = contract["service_ecr_repository_urls"]
    images = values["service_images"]
    auth = aws(contract, "ecr", "get-authorization-token")["authorizationData"][0]
    for service in SERVICES:
        image = images[service]
        repo = repos[service]
        if not image.startswith(repo + "@sha256:"):
            raise ValueError("Image repository differs")
        host, name = repo.split("/", 1)
        digest = image.split("@", 1)[1]
        if auth["proxyEndpoint"].removeprefix("https://") != host:
            raise ValueError("Registry account differs")

        def get(path):
            req = urllib.request.Request(
                "https://" + host + "/v2/" + name + "/" + path,
                headers={
                    "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
                },
            )
            # ECR redirects blob downloads to presigned S3 URLs. Forwarding
            # registry Basic auth there causes InvalidArgument (two auth
            # mechanisms) and sends the registry credential to another host.
            req.add_unredirected_header("Authorization", "Basic " + auth["authorizationToken"])
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)

        manifest = get("manifests/" + digest)
        if "manifests" in manifest:
            candidates = [
                m
                for m in manifest["manifests"]
                if m.get("platform", {}).get("os") == "linux"
                and m["platform"].get("architecture") == "amd64"
            ]
            if len(candidates) != 1:
                raise ValueError(f"{service}: expected one linux/amd64 image")
            manifest = get("manifests/" + candidates[0]["digest"])
        config = get("blobs/" + manifest["config"]["digest"])
        if config.get("architecture") != "amd64" or config.get("os") != "linux":
            raise ValueError(f"{service}: image is not linux/amd64")


def verify_workload(values):
    for service in SERVICES:
        d = json.loads(
            command(
                [
                    "kubectl",
                    "get",
                    "deployment",
                    service,
                    "-n",
                    "travel-planner",
                    "-o",
                    "json",
                ]
            )
        )
        st = d.get("status", {})
        desired = d["spec"]["replicas"]
        if (
            not MIN_REPLICAS[service] <= desired <= 4
            or st.get("observedGeneration", 0) < d["metadata"]["generation"]
            or st.get("updatedReplicas", 0) != desired
            or st.get("readyReplicas", 0) != desired
            or st.get("availableReplicas", 0) != desired
        ):
            raise ValueError(f"{service}: rollout incomplete")
        app = next(
            c
            for c in d["spec"]["template"]["spec"]["containers"]
            if c["name"] == service
        )
        if app["image"] != values["service_images"][service]:
            raise ValueError(f"{service}: deployed image differs")
        h = json.loads(
            command(
                ["kubectl", "get", "hpa", service, "-n", "travel-planner", "-o", "json"]
            )
        )
        if h["spec"]["minReplicas"] != MIN_REPLICAS[service] or h["spec"]["maxReplicas"] != 4:
            raise ValueError(f"{service}: HPA bounds differ")


def main():
    try:
        action = sys.argv[1]
        contract = json.loads(Path(sys.argv[2]).read_text())
        if action == "secrets":
            bootstrap(contract)
        elif action == "verify-secrets":
            verify_secrets()
        elif action == "images":
            inspect_images(contract, json.loads(Path(sys.argv[3]).read_text()))
        elif action == "workload":
            verify_workload(json.loads(Path(sys.argv[3]).read_text()))
        else:
            raise ValueError("Unknown action")
    except Exception:
        # AWS/HTTP exception strings can contain URLs or credential-related context.
        print(
            "MSA runtime validation failed; inspect sanitized stage metadata",
            file=sys.stderr,
        )
        return 1
    print("MSA runtime check passed: " + action)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
