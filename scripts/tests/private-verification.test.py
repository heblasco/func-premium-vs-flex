import importlib.util
from pathlib import Path
import unittest
import tempfile
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("verification", Path(__file__).parents[1] / "private-verification.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class VerificationTests(unittest.TestCase):
    def test_discovery_does_not_invent_an_unreported_worker_count(self):
        target = {"name": "flex", "id": "/test", "hostname": "test.azurewebsites.net", "sku": "FC1"}
        responses = [
            {"properties": {"defaultHostName": target["hostname"], "functionAppConfig": {"runtime": {"version": "22"}}}},
            {"properties": {}},
            {"properties": {"PLAN_LABEL": "flex"}},
            {"functionKeys": {"default": "test-key"}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "package.sha256").write_text("a" * 64)
            with patch.object(verification, "ROOT", root), patch.object(verification, "private_dns"), patch.object(
                verification, "arm", side_effect=responses
            ):
                result = verification.discover({}, target)
                self.assertIsNone(result["configuration"]["workerProcesses"])

    def test_package_is_readable_by_non_root_function_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            (source / "nested").mkdir(parents=True)
            file = source / "nested" / "host.json"
            file.write_text("{}")
            file.chmod(0o600)
            archive = root / "package.zip"
            verification.package_source(source, archive)
            with zipfile.ZipFile(archive) as package:
                self.assertEqual((package.getinfo("nested/").external_attr >> 16) & 0o777, 0o755)
                self.assertEqual((package.getinfo("nested/host.json").external_attr >> 16) & 0o777, 0o644)

    def test_public_dns_is_rejected(self):
        with patch.object(verification.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("8.8.8.8", 443))]):
            with self.assertRaisesRegex(RuntimeError, "Private DNS"):
                verification.private_dns("test.azurewebsites.net")

    def test_upload_verifies_persisted_bytes(self):
        with patch.object(verification, "token", return_value="test-token"), patch.object(
            verification, "request", side_effect=[b"", b"content"]
        ) as request:
            receipt = verification.upload({}, "account", "container", "run/file.json", b"content")
            self.assertEqual(receipt["bytes"], 7)
            self.assertEqual(request.call_args_list[0].args[3]["If-None-Match"], "*")
            self.assertNotIn("test-token", str(receipt))

    def test_upload_rejects_corruption(self):
        with patch.object(verification, "token", return_value="test-token"), patch.object(
            verification, "request", side_effect=[b"", b"other"]
        ):
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                verification.upload({}, "account", "container", "artifact", b"content")


if __name__ == "__main__":
    unittest.main()
