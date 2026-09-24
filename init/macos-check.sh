#!/usr/bin/env bash
# Report how this Mac compares with what .macos would set, without running it.
# Usage: init/macos-check.sh [--probe-writes] [--find-keys] [COMPUTER_NAME]
#
#   --probe-writes  For each defaults domain, export it and import the same
#                   file back. Nothing changes, but a refused write shows which
#                   domains the terminal can't write.
#   --find-keys     Search the system's shared libraries and app binaries for
#                   each key name. A key that is found is still read by
#                   something. Short keys (15 bytes or less) and names built at
#                   run time can't be found this way, so "not found" is only a
#                   hint.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

probe=false
find_keys=false
name=""
for arg in "$@"; do
    case "$arg" in
        --probe-writes) probe=true ;;
        --find-keys) find_keys=true ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) name="$arg" ;;
    esac
done

PROBE="$probe" FIND_KEYS="$find_keys" COMPUTER_NAME="$name" DOTFILES="$(cd .. && pwd)" \
    /usr/bin/python3 - ../.macos <<'EOF'
import os, re, shlex, subprocess, sys, tempfile

macos = sys.argv[1]
probe = os.environ["PROBE"] == "true"
find_keys = os.environ["FIND_KEYS"] == "true"


def run(*cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def commands(path):
    """Yield (line number, command text), joining continuations and skipping heredocs."""
    lines = open(path).read().split("\n")
    i, heredoc = 0, None
    while i < len(lines):
        start, text = i + 1, lines[i]
        i += 1
        if heredoc:
            if text.strip() == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", text)
        if m:
            heredoc = m.group(1)
        while text.rstrip().endswith("\\") and i < len(lines):
            text = text.rstrip()[:-1] + " " + lines[i].strip()
            i += 1
        text = text.strip()
        if text and not text.startswith("#"):
            yield start, text


def expand(word):
    return os.path.expanduser(os.path.expandvars(word))


# `defaults read` prints booleans as 1 or 0
def normalize(kind, value):
    if kind in ("-bool", "-boolean"):
        return "1" if value.lower() in ("true", "yes", "1") else "0"
    if kind in ("-int", "-integer"):
        return str(int(value))
    return value


def same(kind, want, have):
    if kind == "-float":
        try:
            return abs(float(want) - float(have)) < 1e-9
        except ValueError:
            return False
    return want == have


rows, domains, system, skipped = [], {}, [], []
for n, text in commands(macos):
    try:
        words = [expand(w) for w in shlex.split(text)]
    except ValueError:
        skipped.append((n, text))
        continue
    words = [w for w in words if w not in (">", "2>", "/dev/null")]
    sudo = bool(words) and words[0] == "sudo"
    if sudo:
        words = words[1:]
    if not words:
        continue

    if "$COMPUTER_NAME" in text and not os.environ["COMPUTER_NAME"]:
        continue
    if words[0] in ("if", "fi", "then", "else", "for", "do", "done", "while", "echo") or re.match(r"^[A-Z_]+=", words[0]):
        continue

    if words[:3] == ["defaults", "-currentHost", "write"]:
        words = ["defaults", "write", "-currentHost"] + words[3:]
    if words[:2] == ["defaults", "write"]:
        args = words[2:]
        host = []
        if args and args[0] == "-currentHost":
            host, args = ["-currentHost"], args[1:]
        if len(args) < 3:
            skipped.append((n, text))
            continue
        domain, key, rest = args[0], args[1], args[2:]
        kind = rest[0] if rest[0].startswith("-") else "-string"
        value = rest[1] if rest[0].startswith("-") and len(rest) > 1 else rest[0]
        domains.setdefault((tuple(host), domain), sudo)
        code, have, _ = run("defaults", *host, "read", domain, key)
        if kind not in ("-bool", "-boolean", "-int", "-integer", "-float", "-string"):
            status = "not compared (%s)" % kind.lstrip("-")
            want = "…"
        else:
            want = normalize(kind, value)
            status = "not applied" if code else ("applied" if same(kind, want, have) else "different")
        if code:
            have = "<unset>"
        elif "\n" in have:
            have = "set: " + re.sub(r"\s+", " ", have)[:40] + "…"
        rows.append((n, status, domain, key, want, have))
        continue

    cmd = words[0]
    if cmd == "pmset" and len(words) >= 4:
        system.append((n, "pmset", words[1], words[2], words[3]))
    elif cmd in ("systemsetup", "nvram", "scutil", "chflags", "ln"):
        system.append((n, cmd) + tuple(words[1:]))
    else:
        skipped.append((n, text))

# defaults
print("== defaults write (%d lines)" % len(rows))
width = min(60, max(len("%s %s" % (r[2], r[3])) for r in rows))
for n, status, domain, key, want, have in rows:
    if status != "applied":
        name = "%s %s" % (domain, key)
        if len(name) > width:
            name = name[:width - 1] + "…"
        print("%4d  %-24s %-*s  want=%s  have=%s" % (n, status, width, name, want, have))
counts = {}
for r in rows:
    counts[r[1]] = counts.get(r[1], 0) + 1
print("summary:", ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items())))

# system settings, read only
print("\n== system settings")
pm = {"-b": {}, "-c": {}}
section = None
for line in run("pmset", "-g", "custom")[1].splitlines():
    if line.startswith("Battery Power"):
        section = "-b"
    elif line.startswith("AC Power"):
        section = "-c"
    elif section and line.strip():
        parts = line.split()
        pm[section][parts[0]] = parts[1]
# Later pmset lines override earlier ones, so compare only the last value for each setting
final = {}
for n, tool, *args in system:
    if tool == "pmset":
        scope, key, want = args
        for s in (["-b", "-c"] if scope == "-a" else [scope]):
            final[(s, key)] = (n, want)
for (s, key), (n, want) in sorted(final.items(), key=lambda item: item[1][0]):
    have = pm[s].get(key)
    label = {"-b": "battery", "-c": "AC"}[s]
    status = "not supported here" if have is None else ("applied" if have == want else "different")
    print("%4d  pmset %-7s %-14s want=%-6s have=%-6s %s" % (n, label, key, want, have or "-", status))
for n, tool, *args in system:
    if tool == "pmset":
        continue
    elif tool == "systemsetup":
        flag = args[0]
        getter = flag.replace("-set", "-get")
        # sudo keeps TZ, and systemsetup reports it instead of the system time zone
        code, out, err = run("sudo", "-n", "env", "-u", "TZ", "systemsetup", getter)
        want = " ".join(args[1:])
        if code:
            print("%4d  systemsetup %s %s  needs sudo (run `sudo -v` first)" % (n, flag, want))
            continue
        have = out.partition(":")[2].strip()
        # systemsetup reports computer sleep "Off" as "Never"
        applied = have.lower() == want.lower() or (want.lower() == "off" and have == "Never")
        print("%4d  systemsetup %s  want=%s  have=%s  %s" % (n, flag, want, have, "applied" if applied else "different"))
    elif tool == "nvram":
        key, _, want = args[0].partition("=")
        have = run("nvram", key)[1].partition("\t")[2] or "<unset>"
        print("%4d  nvram %s  want=%r  have=%r  %s" % (n, key, want, have, "applied" if have == want else "different"))
    elif tool == "scutil":
        print("%4d  scutil %s  have=%s  want=%s" % (n, args[1], run("scutil", "--get", args[1])[1], args[2] if len(args) > 2 and args[2] else "(unchanged without a name)"))
    elif tool == "chflags":
        target = args[-1]
        flags = run("ls", "-ldO", target)[1].split()
        print("%4d  chflags nohidden %s  %s" % (n, target, "hidden" if "hidden" in flags else "visible (applied)"))
    elif tool == "ln":
        link = args[-1]
        print("%4d  link %s  %s" % (n, link, "exists (applied)" if os.path.lexists(link) else "missing"))

print("\n== actions not checked")
for n, text in skipped:
    print("%4d  %s" % (n, text[:100]))

if probe:
    print("\n== write probe (export each domain, import the same file)")
    for (host, domain), sudo in sorted(domains.items()):
        if sudo:
            print("  skip (needs sudo)  %s" % domain)
            continue
        fd, tmp = tempfile.mkstemp(suffix=".plist")
        os.close(fd)
        try:
            code, _, err = run("defaults", *host, "export", domain, tmp)
            if code:
                print("  no domain yet      %s" % domain)
                continue
            code, _, err = run("defaults", *host, "import", domain, tmp)
            print("  %-18s %s%s" % ("write OK" if code == 0 else "write REFUSED", domain, "" if code == 0 else "  (" + err.splitlines()[-1][:80] + ")"))
        finally:
            os.remove(tmp)

if find_keys:
    print("\n== key names not found in system binaries")
    keys = sorted({r[3] for r in rows})
    fd, keyfile = tempfile.mkstemp()
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(keys) + "\n")
    places = ["/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
              "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
              "/System/Applications", "/System/Library/CoreServices", "/Applications",
              "/System/Library/PrivateFrameworks", "/usr/libexec", "/usr/sbin"]
    found = set()
    for batch in (keys, None):
        todo = keys if batch else sorted(set(keys) - found)
        with open(keyfile, "w") as f:
            f.write("\n".join(todo) + "\n")
        r = subprocess.run(["rg", "-a", "-F", "-o", "--no-filename", "--no-line-number", "-f", keyfile] + places,
                           capture_output=True, text=True, errors="replace")
        found |= set(r.stdout.split())
    os.remove(keyfile)
    for k in keys:
        if k not in found:
            print("  %-60s %s" % (k, "short: search can't tell" if len(k.encode()) <= 15 else "not found"))
EOF
