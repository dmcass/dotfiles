#!/usr/bin/env bash
# Save iTerm2's settings to init/iterm2.plist, without window state and
# machine-specific keys. Run it after changing a setting in iTerm2.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
defaults export com.googlecode.iterm2 "$tmp"

/usr/bin/env python3 - "$tmp" iterm2.plist <<'EOF'
import plistlib, re, sys

# NoSync* is iTerm2's own prefix for keys it never syncs
SKIP = re.compile(
    r"^(NoSync|NSWindow Frame |NSSplitView |NSToolbar |NSNav|kCPK"
    r"|SUHasLaunchedBefore$|SULastCheckTime$|SUUpdateGroupIdentifier$|SUUpdateRelaunchingMarker$"
    r"|iTerm Version$|HotkeyMigratedFromSingleToMulti$|OnePasswordAccount$)"
)
src, dst = sys.argv[1:]
prefs = plistlib.load(open(src, "rb"))
kept = {k: v for k, v in prefs.items() if not SKIP.match(k)}
with open(dst, "wb") as f:
    plistlib.dump(kept, f, sort_keys=True)
print(f"Saved {len(kept)} of {len(prefs)} keys to init/iterm2.plist")
EOF
