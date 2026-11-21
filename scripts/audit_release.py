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
    b"ci_extension", b"luci-app-ci-extension", b"CI integration server", b"CI fixture",
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
        for source in root.rglob("*"):
            if not source.is_file():
                continue
            check_content(source.relative_to(repository), source.read_bytes())
            if source.suffix == ".swift":
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
    result = {"production_sources_checked": audit_sources(args.repository.resolve()),
              "localization": audit_localization(args.repository.resolve()),
              "english_literals": audit_english_literals(args.repository.resolve()),
              "rawvalue_display": audit_rawvalue_display(args.repository.resolve())}
    if args.ipa:
        result["ipa"] = audit_ipa(args.ipa.resolve())
    print(json.dumps(result, ensure_ascii=False, indent=2))



# ---------------------------------------------------------------------------
# Localization audit (localization system package, 2026-11-21)
#
# The rule being enforced: every user-visible string in the app follows
# the system language, and that only stays true if new copy enters the
# localization system instead of landing as a bare literal. A Chinese
# literal is "in the system" when its normalized form is a key of
# App/Localizable.xcstrings (SwiftUI literal call sites localize
# automatically through the catalog; String-producing code resolves the
# same keys through L10n), or — in the kit — when it is passed to
# KitL10n and present in the English table, or is a FieldCatalog label
# present in the table. Anything else fails the audit. Legitimate
# exceptions (literals matched against device data, never displayed
# raw) go in scripts/localization_whitelist.txt, one normalized literal
# per line, with a comment saying why.
# ---------------------------------------------------------------------------

import re

CJK_RE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
SPECIFIER_RE = re.compile(r"%(?:\d+\$)?(?:ll)?[@df]")
_INT_EXPR_RE = re.compile(
    r"(Int\(|\.count\b|\bcount\b|errorCode|\.completed\b|\.total\b|editCount|days|hours|minutes|packets|countedRules|\bstatus\b|\bpid\b)")


def _specifier_for(expr):
    return "%lld" if _INT_EXPR_RE.search(expr) else "%@"


def iter_swift_literals(text):
    """Yield (normalized, line) for every string literal in Swift source.

    Interpolations are normalized to format specifiers (%@ / %lld) the
    same way the compiler forms LocalizedStringKeys; escapes are
    decoded; strings nested inside interpolations are yielded as
    literals of their own. Comments are skipped.
    """
    results = []
    i, n = 0, len(text)

    def parse_string(i):
        # text[i] == '"'; returns (value, exprs, next_index)
        j = i + 1
        buf, exprs = [], []
        while j < n:
            c = text[j]
            if c == "\\":
                nxt = text[j + 1] if j + 1 < n else ""
                if nxt == "(":
                    depth, k = 0, j + 1
                    while k < n:
                        ch = text[k]
                        if ch == '"':
                            inner, _, k2 = parse_string(k)
                            results.append((inner, text.count("\n", 0, k) + 1))
                            k = k2
                            continue
                        if ch == "(":
                            depth += 1
                        elif ch == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        k += 1
                    exprs.append(text[j + 2:k])
                    buf.append("\x01%d\x02" % (len(exprs) - 1))
                    j = k + 1
                    continue
                mapping = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "0": "\0"}
                if nxt == "u":
                    m = re.match(r"u\{([0-9a-fA-F]+)\}", text[j + 1:])
                    buf.append(chr(int(m.group(1), 16)))
                    j += 1 + m.end()
                    continue
                buf.append(mapping.get(nxt, nxt))
                j += 2
                continue
            if c == '"':
                return "".join(buf), exprs, j + 1
            buf.append(c)
            j += 1
        return "".join(buf), exprs, j

    while i < n:
        if text[i:i + 2] == "//":
            end = text.find("\n", i)
            i = end if end >= 0 else n
        elif text[i:i + 2] == "/*":
            end = text.find("*/", i + 2)
            i = end + 2 if end >= 0 else n
        elif text[i:i + 3] == '"""':
            end = text.find('"""', i + 3)
            i = end + 3 if end >= 0 else n
        elif text[i] == '"':
            line = text.count("\n", 0, i) + 1
            value, exprs, i = parse_string(i)
            parts = re.split(r"\x01(\d+)\x02", value)
            normalized = parts[0]
            idx = 1
            while idx < len(parts):
                pos = int(parts[idx])
                normalized += _specifier_for(exprs[pos]) if pos < len(exprs) else "%@"
                normalized += parts[idx + 1]
                idx += 2
            results.append((normalized, line))
        else:
            i += 1
    return results


def _load_whitelist(repository):
    path = repository / "scripts" / "localization_whitelist.txt"
    entries = set()
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line and not line.startswith("#"):
                entries.add(line)
    return entries


def audit_localization(repository):
    errors = []
    whitelist = _load_whitelist(repository)

    catalog_path = repository / "App" / "Localizable.xcstrings"
    if not catalog_path.is_file():
        raise ValueError("Missing App/Localizable.xcstrings")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    keys = set(catalog.get("strings", {}))
    for key, entry in catalog.get("strings", {}).items():
        locs = entry.get("localizations", {})
        for language in ("zh-Hans", "en"):
            if language not in locs:
                errors.append(f"catalog key lacks {language}: {key!r}")
        en_value = locs.get("en", {}).get("stringUnit", {}).get("value", "")
        if SPECIFIER_RE.findall(key) != SPECIFIER_RE.findall(en_value):
            errors.append(f"format specifiers differ between key and en value: {key!r}")

    app_literals = 0
    for source in sorted((repository / "App").rglob("*.swift")):
        for normalized, line in iter_swift_literals(source.read_text(encoding="utf-8")):
            if not CJK_RE.search(normalized):
                continue
            app_literals += 1
            if normalized in keys or normalized in whitelist:
                continue
            errors.append(
                f"{source.relative_to(repository)}:{line}: Chinese literal not in "
                f"Localizable.xcstrings and not whitelisted: {normalized!r}")

    table_path = repository / "Packages/OpenWrtKit/Sources/OpenWrtKit/KitStringsTable.swift"
    table_keys = set()
    if table_path.is_file():
        for normalized, _ in iter_swift_literals(table_path.read_text(encoding="utf-8")):
            table_keys.add(normalized)
    kit_literals = 0
    kit_root = repository / "Packages/OpenWrtKit/Sources"
    for source in sorted(kit_root.rglob("*.swift")):
        if source.name in ("KitStringsTable.swift", "KitStrings.swift"):
            continue
        text = source.read_text(encoding="utf-8")
        lines = text.split("\n")
        for normalized, line in iter_swift_literals(text):
            if not CJK_RE.search(normalized):
                continue
            kit_literals += 1
            if normalized in whitelist:
                continue
            if normalized not in table_keys:
                errors.append(
                    f"{source.relative_to(repository)}:{line}: kit Chinese literal missing "
                    f"from the KitL10n English table and not whitelisted: {normalized!r}")
                continue
            # A table entry alone is not enough outside FieldCatalog
            # (whose labels are data the catalog lookup resolves): the
            # literal must actually be produced through KitL10n.
            if source.name != "FieldCatalog.swift":
                window = "\n".join(lines[max(0, line - 2):line])
                if "KitL10n." not in window:
                    errors.append(
                        f"{source.relative_to(repository)}:{line}: kit Chinese literal is in "
                        f"the English table but not produced through KitL10n: {normalized!r}")

    if errors:
        raise ValueError("Localization audit failed:\n" + "\n".join(errors))
    return {"catalog_keys": len(keys), "app_literals_checked": app_literals,
            "kit_literals_checked": kit_literals, "kit_english_entries": len(table_keys)}



# ---------------------------------------------------------------------------
# English-literal & raw-value audit (package H, 2026-11-21)
#
# The localization audit above only sees literals containing CJK: a
# hard-coded English title ("DHCP and DNS" was the case that shipped)
# and an enum raw value rendered as text are invisible to it. These
# two scans close that blind spot.
#
# English scan: a pure-ASCII literal containing a space and a real
# word is presumed to be interface copy bypassing the catalog.
# Deliberate under-reporting keeps it quiet: single tokens (protocol
# and product names, keys matched against device data) are out of
# scope, and number formats whose only words are universal unit
# symbols ("%@ dBm", "%.1f%% CPU") pass automatically. Genuine
# exceptions go in scripts/english_literal_whitelist.txt — an exact
# literal, or "file:<path>" for one whole fixture/data file — each
# with a comment saying why.
#
# Raw-value scan: every ".rawValue" in App sources must be accounted
# for in scripts/rawvalue_whitelist.txt (path :: line substring, one
# reason comment each). Whitelisted uses are the ones that never
# render as text — storage keys, identifiers, log tags. A value that
# IS displayed must go through a localized mapping instead
# (PackageManager.displayName is the pattern).
# ---------------------------------------------------------------------------

ASCII_WORD_RE = re.compile(r"[A-Za-z]{2,}")
_FORMAT_SPEC_RE = re.compile(r"%(?:\d+\$)?(?:\.\d+)?(?:ll|l)?[@df%]")
_UNIT_TOKENS = {"dBm", "ms", "CPU", "PID", "B/s", "KB/s", "MB/s", "GB/s"}


def _is_unit_format(normalized):
    """True when every word in the literal is a universal unit symbol
    once the format specifiers are removed: the numbers are
    locale-formatted at runtime and the units themselves are not
    translated in any language, so this is not English copy."""
    remainder = _FORMAT_SPEC_RE.sub(" ", normalized)
    tokens = re.findall(r"[A-Za-z]+(?:/[A-Za-z]+)?", remainder)
    return bool(tokens) and all(token in _UNIT_TOKENS for token in tokens)


def _load_english_whitelist(repository):
    literals, files = set(), set()
    path = repository / "scripts" / "english_literal_whitelist.txt"
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("file:"):
                files.add(line[len("file:"):])
            else:
                literals.add(line)
    return literals, files


def audit_english_literals(repository):
    literals_wl, files_wl = _load_english_whitelist(repository)
    errors = []
    checked = 0
    for source in sorted((repository / "App").rglob("*.swift")):
        relative = source.relative_to(repository).as_posix()
        if relative in files_wl:
            continue
        for normalized, line in iter_swift_literals(source.read_text(encoding="utf-8")):
            if CJK_RE.search(normalized) or not normalized.isascii():
                continue
            if " " not in normalized or not ASCII_WORD_RE.search(normalized):
                continue
            checked += 1
            if normalized in literals_wl or _is_unit_format(normalized):
                continue
            errors.append(
                f"{relative}:{line}: English literal bypasses "
                f"Localizable.xcstrings and is not whitelisted: {normalized!r}")
    if errors:
        raise ValueError("English-literal audit failed:\n" + "\n".join(errors))
    return {"english_literals_checked": checked}


def _load_rawvalue_whitelist(repository):
    entries = []
    path = repository / "scripts" / "rawvalue_whitelist.txt"
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            file_part, separator, needle = line.partition(" :: ")
            if separator:
                entries.append((file_part.strip(), needle.strip()))
    return entries


def audit_rawvalue_display(repository):
    whitelist = _load_rawvalue_whitelist(repository)
    errors = []
    checked = 0
    for source in sorted((repository / "App").rglob("*.swift")):
        relative = source.relative_to(repository).as_posix()
        for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
            if ".rawValue" not in line or line.strip().startswith("//"):
                continue
            checked += 1
            if any(relative == path and needle in line for path, needle in whitelist):
                continue
            errors.append(
                f"{relative}:{number}: raw value use is not whitelisted; "
                f"if it can render as text it needs a localized mapping: {line.strip()!r}")
    if errors:
        raise ValueError("Raw-value audit failed:\n" + "\n".join(errors))
    return {"rawvalue_sites_checked": checked}


if __name__ == "__main__":
    main()
