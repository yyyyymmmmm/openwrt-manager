import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from audit_release import (audit_english_literals, audit_ipa, audit_localization,
                           audit_rawvalue_display, audit_sources)


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
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": "26.0",
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



class LocalizationAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "App").mkdir(parents=True)
        (self.root / "Packages/OpenWrtKit/Sources/OpenWrtKit").mkdir(parents=True)
        (self.root / "scripts").mkdir()
        catalog = {"sourceLanguage": "zh-Hans", "version": "1.0", "strings": {
            "概览": {"localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": "概览"}},
                "en": {"stringUnit": {"state": "translated", "value": "Overview"}}}},
            "%lld 项": {"localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": "%lld 项"}},
                "en": {"stringUnit": {"state": "translated", "value": "%lld items"}}}},
        }}
        import json
        (self.root / "App/Localizable.xcstrings").write_text(
            json.dumps(catalog, ensure_ascii=False), encoding="utf-8")

    def test_catalogued_literals_pass(self):
        (self.root / "App/Main.swift").write_text(
            'import SwiftUI\nstruct V: View { var body: some View { Text("概览"); Text("\\(count) 项") } }\n',
            encoding="utf-8")
        result = audit_localization(self.root)
        self.assertEqual(result["catalog_keys"], 2)

    def test_uncatalogued_literal_fails(self):
        (self.root / "App/Main.swift").write_text(
            'import SwiftUI\nstruct V: View { var body: some View { Text("新功能") } }\n',
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "not in Localizable"):
            audit_localization(self.root)

    def test_specifier_mismatch_fails(self):
        import json
        path = self.root / "App/Localizable.xcstrings"
        catalog = json.loads(path.read_text(encoding="utf-8"))
        catalog["strings"]["%lld 项"]["localizations"]["en"]["stringUnit"]["value"] = "%@ items"
        path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "specifiers differ"):
            audit_localization(self.root)


class EnglishLiteralAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "App").mkdir(parents=True)
        (self.root / "scripts").mkdir()

    def write_view(self, body):
        (self.root / "App/View.swift").write_text(
            "import SwiftUI\nstruct V: View { var body: some View { " + body + " } }\n",
            encoding="utf-8")

    def test_hardcoded_english_title_fails(self):
        self.write_view('Text("DHCP and DNS")')
        with self.assertRaisesRegex(ValueError, "English literal"):
            audit_english_literals(self.root)

    def test_whitelisted_literal_passes(self):
        (self.root / "scripts/english_literal_whitelist.txt").write_text(
            "# matched against router ping output, never displayed\n100% packet loss\n",
            encoding="utf-8")
        self.write_view('if output.contains("100% packet loss") { Text("概览") }')
        result = audit_english_literals(self.root)
        self.assertEqual(result["english_literals_checked"], 1)

    def test_unit_format_passes_without_whitelist(self):
        self.write_view('Text("\\(signal) dBm"); Text(String(format: "%.1f%% CPU", cpu))')
        result = audit_english_literals(self.root)
        self.assertEqual(result["english_literals_checked"], 2)

    def test_file_scoped_whitelist_passes(self):
        (self.root / "scripts/english_literal_whitelist.txt").write_text(
            "# seed fixture standing in for router data\nfile:App/Seed.swift\n",
            encoding="utf-8")
        (self.root / "App/Seed.swift").write_text(
            'let titles = ["Custom Rules", "Port Forwards"]\n', encoding="utf-8")
        result = audit_english_literals(self.root)
        self.assertEqual(result["english_literals_checked"], 0)

    def test_single_token_and_chinese_are_out_of_scope(self):
        self.write_view('Text("OpenWrt"); Text("概览")')
        result = audit_english_literals(self.root)
        self.assertEqual(result["english_literals_checked"], 0)


class RawValueAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "App").mkdir(parents=True)
        (self.root / "scripts").mkdir()

    def test_rawvalue_rendered_in_view_fails(self):
        (self.root / "App/View.swift").write_text(
            "import SwiftUI\nstruct V: View { var body: some View { Text(status.rawValue) } }\n",
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Raw-value audit"):
            audit_rawvalue_display(self.root)

    def test_whitelisted_rawvalue_passes(self):
        (self.root / "scripts/rawvalue_whitelist.txt").write_text(
            "# storage key only, never rendered\nApp/Store.swift :: size.rawValue\n",
            encoding="utf-8")
        (self.root / "App/Store.swift").write_text(
            "var body: some View { Text(title).onAppear { saved = size.rawValue } }\n",
            encoding="utf-8")
        result = audit_rawvalue_display(self.root)
        self.assertEqual(result["rawvalue_sites_checked"], 1)

    def test_whitelist_is_file_scoped(self):
        (self.root / "scripts/rawvalue_whitelist.txt").write_text(
            "App/Store.swift :: size.rawValue\n", encoding="utf-8")
        (self.root / "App/Other.swift").write_text(
            "let label = size.rawValue\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Raw-value audit"):
            audit_rawvalue_display(self.root)

    def test_comment_mention_is_ignored(self):
        (self.root / "App/View.swift").write_text(
            "// Never render an enum .rawValue as text.\nimport SwiftUI\n",
            encoding="utf-8")
        result = audit_rawvalue_display(self.root)
        self.assertEqual(result["rawvalue_sites_checked"], 0)


if __name__ == "__main__":
    unittest.main()
