#!/usr/bin/env python3
"""Fail closed on embedded server keys. Diagnostics contain paths/labels, never key values."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_URL = "https://example.supabase.co"
DEFAULT_KEY = "replace-with-public-publishable-key"


def jwt_role(value):
    try:
        parts = value.split(".")
        if len(parts) != 3:
            return None
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("role")
    except (ValueError, TypeError, AttributeError):
        return None


def validate_ios_config(url, key):
    if url == DEFAULT_URL and key == DEFAULT_KEY:
        return  # An intentionally unconfigured development build, with no credentials.
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path not in ("", "/") or "$(" in url):
        raise ValueError("iOS requires a project HTTPS origin without credentials, paths, query or fragment")
    if not (re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]{8,}", key) or jwt_role(key) == "anon"):
        raise ValueError("iOS accepts only a Supabase publishable key or a legacy anon key; server/session keys are forbidden")


SECRET_PATTERNS = (
    ("OpenAI secret", re.compile(rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}")),
    ("Supabase secret", re.compile(rb"\bsb_secret_[A-Za-z0-9_-]{12,}")),
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
)
JWT = re.compile(rb"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")


def inspect_bytes(data):
    findings = [(label, match.start()) for label, pattern in SECRET_PATTERNS for match in pattern.finditer(data)]
    for match in JWT.finditer(data):
        if jwt_role(match.group().decode("ascii")) in ("service_role", "authenticated"):
            findings.append(("privileged/session JWT", match.start()))
    return findings


def credential_path(path):
    name = Path(path).name
    return (name == ".env" or name.startswith(".env.") and name != ".env.example"
            or name == "Config.local.xcconfig" or Path(path).suffix in (".p8", ".p12", ".mobileprovision"))


def source_paths():
    if (ROOT / ".git").exists():
        result = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                cwd=ROOT, check=True, capture_output=True)
        return [ROOT / os.fsdecode(p) for p in result.stdout.split(b"\0") if p]
    # This workspace has not been initialized as a Git repository.
    ignored = {".git", ".tools", ".build", "build", "DerivedData", "__pycache__", "xcuserdata", ".temp", ".branches"}
    paths = []
    for folder, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ignored]
        paths.extend(Path(folder) / f for f in files if not credential_path(f))
    return paths


def scan(paths, source=False):
    count = 0
    failures = 0
    for path in paths:
        if not path.is_file() or path.is_symlink():
            continue
        count += 1
        label = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else path.name
        if source and credential_path(path):
            print("FAIL: {}: credential configuration is in the Git file set".format(label))
            failures += 1
        data = path.read_bytes()
        for kind, offset in inspect_bytes(data):
            # Do not print the matched bytes, surrounding text, or complete plist.
            line = data[:offset].count(b"\n") + 1
            print("FAIL: {}:{}: {} detected".format(label, line, kind))
            failures += 1
    if failures:
        raise ValueError("Secret scan failed; remove secrets and rotate any exposed credentials")
    print("PASS: no recognized secret values in {} files".format(count))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("ios-config", "source", "bundle"))
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    try:
        if args.mode == "ios-config":
            validate_ios_config(os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_PUBLISHABLE_KEY", ""))
            print("PASS: iOS build configuration contains only permitted public configuration")
        elif args.mode == "source":
            scan(source_paths(), source=True)
            if not (ROOT / ".git").exists():
                print("NOTE: no Git repository/history exists here; source and ignore rules are the available evidence")
        else:
            if not args.path or not Path(args.path).is_dir():
                raise ValueError("Provide a built .app directory")
            scan(Path(args.path).rglob("*"))
    except (ValueError, OSError) as error:
        # Validation messages are static; never echo keys or arbitrary parsed input.
        print("FAIL: configuration/secret check did not pass" if not isinstance(error, ValueError) else "FAIL: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
