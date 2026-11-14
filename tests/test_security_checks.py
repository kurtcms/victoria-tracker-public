import base64
import importlib.util
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("security_checks", Path(__file__).resolve().parents[1] / "scripts/security_checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def token(role):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return part({"alg": "HS256"}) + "." + part({"role": role}) + ".fake-signature"


class SecurityChecksTests(unittest.TestCase):
    def test_git_ignore_rules_protect_local_credentials(self):
        with tempfile.TemporaryDirectory(prefix="victoria-ignore-audit-") as folder:
            shutil.copy(checks.ROOT / ".gitignore", Path(folder) / ".gitignore")
            subprocess.run(["git", "init", "--quiet", "--template=", folder], check=True, capture_output=True)
            protected = ["ios/Config.local.xcconfig", "supabase/.env.local", ".env", "signing.p8", "signing.p12", "signing.mobileprovision", ".tools/supabase", "build/DerivedData/output"]
            candidates = protected + ["ios/Config.xcconfig", "supabase/.env.example"]
            result = subprocess.run(["git", "-C", folder, "check-ignore", "--stdin"], input="\n".join(candidates), text=True, check=True, capture_output=True)
            self.assertEqual(set(result.stdout.splitlines()), set(protected))

    def test_allows_intentionally_unconfigured_build(self):
        checks.validate_ios_config(checks.DEFAULT_URL, checks.DEFAULT_KEY)

    def test_allows_public_keys_only(self):
        for key in ["sb_publishable_" + "a" * 32, token("anon")]:
            checks.validate_ios_config("https://project.supabase.co", key)

    def test_rejects_server_and_session_keys(self):
        for key in ["sk-" + "a" * 32, "sb_secret_" + "a" * 32, token("service_role"), token("authenticated"), "", checks.DEFAULT_KEY]:
            with self.assertRaises(ValueError):
                checks.validate_ios_config("https://project.supabase.co", key)

    def test_rejects_credential_urls_and_non_https(self):
        for url in ["http://project.supabase.co", "https://user:secret@project.supabase.co", "https://project.supabase.co?token=x", "https://project.supabase.co/path"]:
            with self.assertRaises(ValueError):
                checks.validate_ios_config(url, token("anon"))

    def test_scans_secret_families_without_echoing_values(self):
        for value in ["sk-" + "a" * 32, "sb_secret_" + "a" * 32, token("service_role"), token("authenticated"), "-----BEGIN " + "PRIVATE KEY-----"]:
            result = checks.inspect_bytes(value.encode())
            self.assertTrue(result)
            self.assertNotIn(value, str(result))
        self.assertFalse(checks.inspect_bytes(token("anon").encode()))


if __name__ == "__main__":
    unittest.main()
