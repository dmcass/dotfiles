#!/usr/bin/env bash
# Load init/iterm2.plist into iTerm2's settings. Keys that are not in the file
# (window state, machine-specific keys) keep their current values.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# iTerm2 writes its settings on quit, which would overwrite the import
if pgrep -xq iTerm2; then
    echo "Quit iTerm2 first, then run this from another terminal." >&2
    exit 1
fi

current="$(mktemp)"
trap 'rm -f "$current"' EXIT
defaults export com.googlecode.iterm2 "$current" 2>/dev/null || echo '{}' | plutil -convert xml1 -o "$current" -

/usr/bin/env python3 - "$current" iterm2.plist <<'EOF'
import plistlib, sys
current, saved = sys.argv[1:]
prefs = plistlib.load(open(current, "rb"))
prefs.update(plistlib.load(open(saved, "rb")))
with open(current, "wb") as f:
    plistlib.dump(prefs, f)
EOF
defaults import com.googlecode.iterm2 "$current"
echo "Loaded init/iterm2.plist into iTerm2's settings"
