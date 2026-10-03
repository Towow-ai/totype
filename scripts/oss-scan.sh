#!/bin/bash
# Pre-publication scan for private words, secrets, personal paths and emails.
#
#   scripts/oss-scan.sh <patterns-file> <dir>
#
# The patterns file lives outside the repository (it is itself a list of
# private words). One regular expression per line (Python `re` syntax, so
# \b and lookaheads work); blank lines and lines starting with # are ignored;
# a line starting with ! is an allow rule: a finding whose source line matches
# it is dropped. Patterns are matched against file contents and relative paths.
#
# Built-in checks: common API-key shapes (sk-, AKIA, ghp_, xox*, AIza, private
# key blocks), long mixed-case base64-looking tokens, absolute /Users/ paths,
# email addresses. Binary files, .git, .build and build/ are skipped.
#
# Exit status: 0 clean, 1 findings, 2 usage error.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <patterns-file> <dir>" >&2
    exit 2
fi
[[ -f "$1" ]] || { echo "patterns file not found: $1" >&2; exit 2; }
[[ -d "$2" ]] || { echo "directory not found: $2" >&2; exit 2; }

exec python3 - "$1" "$2" <<'PY'
import os, re, sys

patterns_file, root = sys.argv[1], os.path.abspath(sys.argv[2])

deny, allow = [], []
with open(patterns_file, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("!"):
            allow.append(re.compile(line[1:]))
        else:
            deny.append((line, re.compile(line)))

builtin = [
    ("api-key sk-", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("aws key AKIA", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("github token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("google key AIza", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("absolute user path", re.compile(r"/Users/[A-Za-z0-9._-]+")),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
]
email_ok = re.compile(r"@[0-9]x\.[a-z]+$|@(example\.(com|org|net)|users\.noreply\.github\.com)$|^noreply@", re.I)
token = re.compile(r"[A-Za-z0-9+/_=-]{40,}")
hexonly = re.compile(r"^[0-9a-fA-F]+$")

skip_dirs = {".git", ".build", "build", "node_modules", "DerivedData"}
findings = []

def allowed(line):
    return any(a.search(line) for a in allow)

def add(rel, lineno, kind, text, line):
    if allowed(line):
        return
    findings.append((rel, lineno, kind, text if len(text) <= 70 else text[:67] + "..."))

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d not in skip_dirs)
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        for label, rx in deny:
            m = rx.search(rel)
            if m:
                add(rel, 0, "path matches /%s/" % label, m.group(0), rel)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for label, rx in deny:
                m = rx.search(line)
                if m:
                    add(rel, lineno, "private /%s/" % label, m.group(0), line)
            for kind, rx in builtin:
                for m in rx.finditer(line):
                    if kind == "email" and email_ok.search(m.group(0)):
                        continue
                    add(rel, lineno, kind, m.group(0), line)
            for m in token.finditer(line):
                t = m.group(0)
                if hexonly.match(t) or "/" in t and t.count("/") > 2:
                    continue
                if (re.search(r"[A-Z]", t) and re.search(r"[a-z]", t)
                        and len(re.findall(r"[0-9]", t)) >= 6
                        and len(set(t)) > 20 and not t.startswith(("http", "VerbatimVoice"))):
                    add(rel, lineno, "long base64-like token", t, line)

if findings:
    for rel, lineno, kind, text in findings:
        loc = rel if lineno == 0 else "%s:%d" % (rel, lineno)
        print("%s: %s: %s" % (loc, kind, text))
    print("\n%d finding(s) in %s" % (len(findings), root), file=sys.stderr)
    sys.exit(1)
print("oss-scan: clean (%s)" % root, file=sys.stderr)
PY
