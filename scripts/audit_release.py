"""Reject test/demo code in production sources and an unsigned release bundle."""

import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path


FORBIDDEN_MARKERS = (
    b"DemoData", b"loadDemo", b"enterDemo", b"isDemo", b"--demo",
    b"demoModeButton", b"ci-only-password", b"ci-router",
    b"ci_extension", b"luci-app-ci-extension", b"CI integration server",
)


def check_content(name, data):
    for marker in FORBIDDEN_MARKERS:
        if marker in data:
            raise ValueError(f"Production test/demo marker {marker.decode()!r} in {name}")


def audit_sources(repository):
    roots = (repository / "App", repository / "Packages/OpenWrtKit/Sources")
    count = 0
    for root in roots:
        if not root.is_dir():
            raise ValueError(f"Missing production source directory: {root}")
        for source in root.rglob("*.swift"):
            check_content(source.relative_to(repository), source.read_bytes())
            count += 1
    if not count:
        raise ValueError("No production Swift sources found")
    return count


def audit_ipa(path):
    prefix = "Payload/OpenWrtManager.app/"
    with zipfile.ZipFile(path) as bundle:
        if bundle.testzip():
            raise ValueError("IPA ZIP integrity check failed")
        names = bundle.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate bundle entries")
        for name in names:
            if not name.startswith(prefix) and name != "Payload/":
                raise ValueError(f"Unexpected IPA entry: {name}")
            if name.endswith((".py", ".swift", ".p12")) or any(
                part in name for part in (".xctest", "AppUITests", "ui_test_router", "__pycache__", "_CodeSignature", "embedded.mobileprovision")
            ):
                raise ValueError(f"Unexpected resource in unsigned IPA: {name}")
            if not name.endswith("/"):
                check_content(name, bundle.read(name))
        info = plistlib.loads(bundle.read(prefix + "Info.plist"))
        privacy = plistlib.loads(bundle.read(prefix + "PrivacyInfo.xcprivacy"))
        executable = bundle.read(prefix + info["CFBundleExecutable"])
        if len(executable) < 32 or struct.unpack_from("<II", executable) != (0xFEEDFACF, 0x0100000C):
            raise ValueError("Expected an ARM64 Mach-O iPhone executable")
        if info.get("CFBundleIdentifier") != "app.openwrtmanager.ios":
            raise ValueError("Unexpected bundle identifier")
        if privacy.get("NSPrivacyTracking") is not False:
            raise ValueError("Unexpected privacy tracking declaration")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        return {
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "minimum_ios": info["MinimumOSVersion"],
            "bundle_entries": len(names),
            "bytes": path.stat().st_size,
            "sha256": digest,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    result = {"production_sources_checked": audit_sources(args.repository.resolve())}
    if args.ipa:
        result["ipa"] = audit_ipa(args.ipa.resolve())
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
