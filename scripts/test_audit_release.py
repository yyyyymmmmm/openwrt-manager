import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from audit_release import audit_ipa, audit_sources


class ReleaseAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "App").mkdir()
        (self.root / "Packages/OpenWrtKit/Sources").mkdir(parents=True)
        (self.root / "App/Main.swift").write_text("import SwiftUI\n", encoding="utf-8")

    def test_test_fixture_outside_production_is_allowed(self):
        (self.root / "AppUITests").mkdir()
        (self.root / "AppUITests/Test.swift").write_bytes(b"ci-only-password")
        self.assertEqual(audit_sources(self.root), 1)

    def test_production_code_cannot_load_demonstration_data(self):
        (self.root / "App/Main.swift").write_bytes(b"let state = DemoData.snapshot")
        with self.assertRaisesRegex(ValueError, "Production test/demo marker"):
            audit_sources(self.root)

    def test_bundled_json_cannot_contain_test_data(self):
        (self.root / "App/state.json").write_bytes(b'{"hostname":"ci-router"}')
        with self.assertRaisesRegex(ValueError, "state.json"):
            audit_sources(self.root)

    def bundle(self, entries):
        prefix = "Payload/OpenWrtManager.app/"
        path = self.root / "test.ipa"
        contents = {
            "Info.plist": plistlib.dumps({
                "CFBundleExecutable": "OpenWrtManager", "CFBundleIdentifier": "app.openwrtmanager.ios",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": "17.0",
            }),
            "PrivacyInfo.xcprivacy": plistlib.dumps({"NSPrivacyTracking": False}),
            "OpenWrtManager": struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(24),
        }
        contents.update(entries)
        with zipfile.ZipFile(path, "w") as bundle:
            for name, data in contents.items():
                bundle.writestr(prefix + name, data)
        return path

    def test_ipa_rejects_test_data_in_resources(self):
        with self.assertRaisesRegex(ValueError, "Production test/demo marker"):
            audit_ipa(self.bundle({"state.json": b'{"name":"CI fixture"}'}))

    def test_unsigned_ipa_rejects_test_bundle_and_signing_material(self):
        for name in ("Tests.xctest/Info.plist", "private.p12", "embedded.mobileprovision", "ui_test_router.py"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Unexpected resource"):
                audit_ipa(self.bundle({name: b"data"}))

    def test_ipa_rejects_wrong_executable_architecture(self):
        with self.assertRaisesRegex(ValueError, "ARM64"):
            audit_ipa(self.bundle({"OpenWrtManager": b"not an iPhone executable"}))


if __name__ == "__main__":
    unittest.main()
