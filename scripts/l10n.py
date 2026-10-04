#!/usr/bin/env python3
"""Localization tooling for the macOS app.

The source language is Chinese: the Chinese text itself is the lookup key
(`String(localized: "已插入 \\(n) 字")` -> key "已插入 %lld 字"). That keeps the shared
iOS/test builds, which have no string tables, showing exactly the original Chinese.

  l10n.py check [--keys-dir DIR]   verify tables and code (see scripts/check_l10n.sh)
  l10n.py sync-zh                  regenerate zh-Hans/Localizable.strings from the English keys
  l10n.py warn-hardcoded           list Chinese literals that are not localized (never fails)

Tables: VerbatimVoice/Resources/{en,zh-Hans}.lproj/Localizable.strings
Exempt a literal from the hard-coded warning with a trailing `// l10n:ignore`.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "VerbatimVoice" / "Resources"
EN = RES / "en.lproj" / "Localizable.strings"
ZH = RES / "zh-Hans.lproj" / "Localizable.strings"
SWIFT_DIRS = [ROOT / "VerbatimVoice", ROOT / "VerbatimVoiceCore" / "Sources"]

HEADER = "/* {what}. */\n"
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|q)?[@dDiuUxXoOfeEgGcCsSp]")
CJK = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")


def unescape(s):
    return (s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\"))


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def read_table(path):
    table, errors = {}, []
    lines = path.read_text(encoding="utf-8").splitlines()
    in_comment = False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if in_comment:
            in_comment = "*/" not in stripped
            continue
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            in_comment = "*/" not in stripped
            continue
        m = ENTRY.match(stripped)
        if not m:
            errors.append(f"{path.name}:{number}: not a key = value line: {stripped[:60]}")
            continue
        key, value = unescape(m.group(1)), unescape(m.group(2))
        if key in table:
            errors.append(f"{path.relative_to(ROOT)}:{number}: duplicate key {key!r}")
        table[key] = value
    return table, errors


def specs(s):
    """Format specifiers in order; positional ones (`%2$@`) are listed by position so a
    translation may reorder them."""
    found = [m.group(0) for m in SPEC.finditer(s.replace("%%", ""))]
    if any(re.match(r"%\d+\$", f) for f in found):
        return sorted(re.sub(r"^%\d+\$", "%", f) for f in found)
    return found


def write_table(path, table, what):
    body = "".join(f'"{escape(k)}" = "{escape(v)}";\n' for k, v in sorted(table.items()))
    path.write_text(HEADER.format(what=what) + "\n" + body, encoding="utf-8")


def compiler_keys(keys_dir):
    keys = {}
    for f in sorted(Path(keys_dir).glob("*.stringsdata")):
        data = json.loads(f.read_text(encoding="utf-8"))
        for entry in data.get("tables", {}).get("Localizable", []):
            loc = entry.get("location", {})
            keys.setdefault(entry["key"], f"{data.get('source', f.name)}:{loc.get('startingLine', '?')}")
    return keys


def cmd_check(args):
    keys_dir = args[args.index("--keys-dir") + 1] if "--keys-dir" in args else None
    failures = []
    en, errs = read_table(EN)
    failures += errs
    zh, errs = read_table(ZH)
    failures += errs
    for k in sorted(set(en) - set(zh)):
        failures.append(f"key only in en: {k!r}")
    for k in sorted(set(zh) - set(en)):
        failures.append(f"key only in zh-Hans: {k!r}")
    for k, v in zh.items():
        if v != k:
            failures.append(f"zh-Hans value differs from its key (Chinese must stay as written): {k!r}")
    for k, v in en.items():
        if not v.strip():
            failures.append(f"empty English value: {k!r}")
        elif (sorted(specs(k)) if "$" in v else specs(k)) != specs(v):
            failures.append(f"format specifiers differ: {k!r} -> {v!r}")
        elif CJK.search(v):
            failures.append(f"English value still contains Chinese: {k!r} -> {v!r}")
    if keys_dir:
        used = compiler_keys(keys_dir)
        for k, where in sorted(used.items(), key=lambda kv: kv[1]):
            if k not in en:
                if where.split(":")[0].endswith("DesignPreview.swift"):
                    # Debug-only snapshot tool: its own labels need no translation.
                    print(f"warning: {where}: preview-only key not in the tables: {k!r}")
                else:
                    failures.append(f"{where}: key not in the tables: {k!r}")
        unused = sorted(set(en) - set(used))
        for k in unused:
            print(f"warning: table key not used by any call the compiler can see: {k!r}")
        print(f"{len(used)} keys found in code, {len(en)} in the tables")
    if failures:
        print("\n".join(failures))
        print(f"FAILED: {len(failures)} problem(s)")
        return 1
    print(f"ok  en and zh-Hans tables agree ({len(en)} keys)")
    return 0


def cmd_sync_zh(_args):
    en, errs = read_table(EN)
    if errs:
        print("\n".join(errs))
        return 1
    write_table(ZH, {k: k for k in en}, "Generated from the English keys by scripts/l10n.py sync-zh; do not edit")
    print(f"zh-Hans: {len(en)} keys")
    return 0


def cmd_warn_hardcoded(args):
    # Lines the compiler already resolved to a localized key (SwiftUI literals, wrapper
    # functions) are not hard-coded; the keys directory comes from check_l10n.sh.
    resolved = set()
    if "--keys-dir" in args:
        for f in Path(args[args.index("--keys-dir") + 1]).glob("*.stringsdata"):
            data = json.loads(f.read_text(encoding="utf-8"))
            for entry in data.get("tables", {}).get("Localizable", []):
                resolved.add((Path(data["source"]).resolve(), entry["location"]["startingLine"]))
    literal = re.compile(r'"(?:[^"\\\n]|\\.)*"')
    localized = re.compile(r'(String\(localized:|LocalizedStringKey\(|L10n\.|\bText\(|\bButton\(|\bLabel\(|\bToggle\(|\bTextField\(|'
                           r'\bPicker\(|\bSection\(|\.help\(|\.navigationTitle\()\s*$')
    found = 0
    for base in SWIFT_DIRS:
        for path in sorted(base.rglob("*.swift")):
            if path.name == "DesignPreview.swift":
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                code = line.split("//")[0] if "// l10n:ignore" not in line else ""
                if not code or not CJK.search(code):
                    continue
                if "l10n:ignore" in line or (path.resolve(), number) in resolved:
                    continue
                for m in literal.finditer(code):
                    if not CJK.search(m.group(0)):
                        continue
                    before = code[:m.start()]
                    if localized.search(before) or re.search(r"String\(localized:\s*$", before):
                        continue
                    print(f"warning: {path.relative_to(ROOT)}:{number}: Chinese literal outside a localization call: {m.group(0)[:50]}")
                    found += 1
    print(f"{found} possible hard-coded Chinese literal(s) (warning only; exempt with `// l10n:ignore`)")
    return 0


if __name__ == "__main__":
    commands = {"check": cmd_check, "sync-zh": cmd_sync_zh, "warn-hardcoded": cmd_warn_hardcoded}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        print(__doc__)
        sys.exit(2)
    sys.exit(commands[sys.argv[1]](sys.argv[2:]))
