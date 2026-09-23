#!/usr/bin/env bash
# Link the dotfiles in this repository into the home folder.
# A file that is in the way is moved to ~/.dotfiles-backup/<time>/.
# Usage: ./bootstrap.sh [--dry-run]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
DOTFILES="$PWD"
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

run() { if $DRY_RUN; then echo "would: $*"; else "$@"; fi; }

# Every tracked file, except the ones that are not home-folder dotfiles
git ls-files | grep -vE '^(bootstrap\.sh|Brewfile.*|\.macos|README\.md|LICENSE-MIT\.txt|init/)|\.gitkeep$' |
while read -r f; do
    src="$DOTFILES/$f"
    dst="$HOME/$f"
    [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && continue
    run mkdir -p "$(dirname "$dst")"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        run mkdir -p "$(dirname "$BACKUP/$f")"
        run mv "$dst" "$BACKUP/$f"
    fi
    run ln -s "$src" "$dst"
    $DRY_RUN || echo "linked $f"
done

# Folders that .vimrc writes to
run mkdir -p ~/.vim/backups ~/.vim/swaps ~/.vim/undo

# GnuPG warns if its home folder is readable by others
run chmod 700 ~/.gnupg
