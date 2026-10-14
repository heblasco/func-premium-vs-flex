"""Private Azure verification using IMDS, ARM and Blob OAuth; no operator credentials."""
import argparse
import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
ARM = "https://management.azure.com"
API = "?api-version=2023-12-01"


def request(url, method="GET", data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=180) as response:
        body = response.read()
        return json.loads(body) if body and response.headers.get_content_type() == "application/json" else body


def token(config, resource=ARM + "/"):
    query = urllib.parse.urlencode({
        "api-version": "2018-02-01", "resource": resource,
        "client_id": config["runner"]["client_id"],
    })
    return request("http://169.254.169.254/metadata/identity/oauth2/token?" + query,
                   headers={"Metadata": "true"})["access_token"]


def arm(config, path, method="GET"):
    return request(ARM + path + API, method, headers={"Authorization": "Bearer " + token(config)})


def private_dns(host):
    addresses = sorted({item[4][0] for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)})
    if not addresses or not all(ipaddress.ip_address(address).is_private for address in addresses):
        raise RuntimeError("Private DNS check failed for " + host)
    print(json.dumps({"privateHost": host, "addresses": addresses}), flush=True)


def upload(config, account, container, name, content):
    host = account + ".blob.core.windows.net"
    url = "https://" + host + "/" + container + "/" + urllib.parse.quote(name, safe="/")
    headers = {
        "Authorization": "Bearer " + token(config, "https://storage.azure.com/"),
        "x-ms-version": "2023-11-03", "x-ms-blob-type": "BlockBlob",
        "Content-Type": "application/octet-stream", "If-None-Match": "*",
    }
    try:
        request(url, "PUT", content, headers)
    except urllib.error.HTTPError as error:
        if error.code != 412:
            raise
    stored = request(url, headers={"Authorization": headers["Authorization"], "x-ms-version": "2023-11-03"})
    if hashlib.sha256(stored).digest() != hashlib.sha256(content).digest():
        raise RuntimeError("Persisted blob does not match source: " + name)
    return {"blob": name, "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def package_source(source, archive):
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for file in sorted(source.rglob("*")):
            relative = file.relative_to(source).as_posix()
            info = zipfile.ZipInfo.from_file(file, relative)
            # Flex runs as a non-root user. The executor's restrictive umask
            # must not become unreadable permissions in the mounted package.
            mode = 0o755 if file.is_dir() or file.stat().st_mode & 0o111 else 0o644
            kind = stat.S_IFDIR if file.is_dir() else stat.S_IFREG
            info.external_attr = (kind | mode) << 16
            if file.is_dir():
                info.external_attr |= 0x10
            package.writestr(info, b"" if file.is_dir() else file.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)


def build(config):
    subprocess.run(["npm", "ci", "--omit=dev", "--no-audit", "--no-fund"], cwd=ROOT / "src", check=True)
    archive = ROOT / "package.zip"
    package_source(ROOT / "src", archive)
    content = archive.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    ep = config["ep"]
    private_dns(ep["storage_account"] + ".blob.core.windows.net")
    result = upload(config, ep["storage_account"], ep["container"], digest + ".zip", content)
    (ROOT / "package.sha256").write_text(digest, encoding="ascii")
    print(json.dumps({"package": result, "node": subprocess.check_output(["node", "--version"], text=True).strip()}))


def publish(config, targets):
    content = (ROOT / "package.zip").read_bytes()
    if hashlib.sha256(content).hexdigest() != (ROOT / "package.sha256").read_text().strip():
        raise RuntimeError("Package checksum mismatch")
    for target in targets:
        if target["name"] == "elastic-premium":
            raise RuntimeError("EP uses its immutable blob package, not SCM publication")
        host = target["hostname"].replace(".azurewebsites.net", ".scm.azurewebsites.net")
        private_dns(host)
        base = "https://" + host
        endpoint = "/api/publish?RemoteBuild=false&Deployer=private-verification" if target["name"] == "flex" else "/api/zipdeploy?isAsync=true"
        headers = {"Authorization": "Bearer " + token(config), "Content-Type": "application/zip"}
        started = datetime.datetime.now(datetime.timezone.utc)
        request(base + endpoint, "POST", content, headers)
        for _ in range(120):
            time.sleep(5)
            status = request(base + "/api/deployments/latest", headers={"Authorization": "Bearer " + token(config)})
            stamp = status.get("received_time") or status.get("start_time")
            current = stamp and datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")) >= started - datetime.timedelta(seconds=5)
            if current and status.get("status") == 3:
                raise RuntimeError("SCM deployment failed for " + target["name"])
            if current and status.get("status") == 4:
                print(json.dumps({"published": target["name"], "deploymentId": status["id"],
                                  "packageSha256": hashlib.sha256(content).hexdigest()}), flush=True)
                break
        else:
            raise RuntimeError("SCM deployment did not complete for " + target["name"])


def discover(config, target):
    private_dns(target["hostname"])
    site = arm(config, target["id"])["properties"]
    web = arm(config, target["id"] + "/config/web")["properties"]
    settings = arm(config, target["id"] + "/config/appsettings/list", "POST")["properties"]
    if site["defaultHostName"] != target["hostname"]:
        raise RuntimeError("Hostname changed")
    flex = site.get("functionAppConfig") or {}
    scale = flex.get("scaleAndConcurrency") or {}
    runtime = (flex.get("runtime") or {}).get("version") if target["name"] == "flex" else web.get("linuxFxVersion", "").split("|")[-1]
    if runtime != "22":
        raise RuntimeError("Expected Node 22 on every comparison arm")
    expected = "premium" if target["name"] == "dedicated" else target["name"]
    if settings.get("PLAN_LABEL") != expected:
        raise RuntimeError("Unexpected plan label")
    keys = arm(config, target["id"] + "/host/default/listkeys", "POST")
    key = keys.get("functionKeys", {}).get("default")
    if not key:
        raise RuntimeError("Default function key unavailable")
    ready = sum(item["instanceCount"] for item in (scale.get("alwaysReady") or []) if item["name"] == "http")
    return {
        "name": target["name"], "url": "https://" + target["hostname"] + "/api/stress",
        "resourceId": target["id"], "expectedPlan": expected, "key": key,
        "configuration": {
            "sku": target["sku"], "alwaysReady": ready if target["name"] == "flex" else web.get("minimumElasticInstanceCount"),
            "prewarmed": web.get("preWarmedInstanceCount"), "alwaysOn": web.get("alwaysOn"),
            "maximumInstances": scale.get("maximumInstanceCount") if target["name"] == "flex" else web.get("functionAppScaleLimit"),
            "memoryMB": scale.get("instanceMemoryMB"), "httpConcurrency": (scale.get("triggers") or {}).get("http", {}).get("perInstanceConcurrency"),
            "workerProcesses": int(settings["FUNCTIONS_WORKER_PROCESS_COUNT"]) if "FUNCTIONS_WORKER_PROCESS_COUNT" in settings else None,
            "lastModifiedUtc": site.get("lastModifiedTimeUtc"),
            "packageSha256": (ROOT / "package.sha256").read_text().strip(),
        },
    }


def run(config, targets):
    output = ROOT / "results"
    output.mkdir(exist_ok=True)
    existing = set(output.iterdir())
    environment = dict(os.environ)
    environment["STARTUP_CONFIG"] = json.dumps({"options": config["options"],
                                               "targets": [discover(config, target) for target in targets]})
    result = subprocess.run(["node", str(ROOT / "startup-runner.js"), str(output)],
                            env=environment, capture_output=True, text=True)
    del environment["STARTUP_CONFIG"]
    created = set(output.iterdir()) - existing
    if len(created) != 1:
        raise RuntimeError("Expected one persisted benchmark run")
    directory = created.pop()
    runner = config["runner"]
    private_dns(runner["results_account"] + ".blob.core.windows.net")
    inventory = []
    for file in sorted(directory.iterdir()):
        inventory.append(upload(config, runner["results_account"], runner["results_container"],
                                directory.name + "/" + file.name, file.read_bytes()))
    manifest = json.loads((directory / "manifest.json").read_text())
    summary = json.loads((directory / "summary.json").read_text())
    receipt = {"runId": directory.name, "status": manifest["status"], "artifacts": inventory,
               "summary": [row for row in summary if row["cohort"] == "all"]}
    receipt_bytes = json.dumps(receipt, indent=2).encode()
    upload(config, runner["results_account"], runner["results_container"], directory.name + "/receipt.json", receipt_bytes)
    (directory / "receipt.json").write_bytes(receipt_bytes)
    compact = dict(receipt)
    compact["artifacts"] = {"receiptBlob": directory.name + "/receipt.json", "verifiedFiles": len(inventory)}
    print(json.dumps(compact, separators=(",", ":")), flush=True)
    if result.returncode:
        raise RuntimeError("Benchmark failed; complete failure artifacts persisted")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["build", "publish", "run", "sync"])
    args = parser.parse_args()
    config = json.loads((ROOT / "config.json").read_text())
    targets = config["targets"]
    if args.action == "build":
        build(config)
    elif args.action == "publish":
        publish(config, targets)
    elif args.action == "run":
        run(config, targets)
    else:
        for target in targets:
            arm(config, target["id"] + "/syncfunctiontriggers", "POST")
            print(json.dumps({"synced": target["name"]}))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        location = urllib.parse.urlsplit(error.url)
        print(f"Verification HTTP failure: {error.code} at {location.hostname}{location.path}", file=sys.stderr)
        if location.hostname == "management.azure.com":
            details = json.loads(error.read()).get("error", {})
            print(json.dumps({"code": details.get("code"), "message": details.get("message")}), file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        print("Verification failed: " + str(error), file=sys.stderr)
        sys.exit(1)
