#!/usr/bin/env bash
# Copies the scripts to ~/.claude/bin and the slash commands to ~/.claude/commands.
# Existing files with the same name are backed up as <name>.bak-<date> first.
set -euo pipefail
cd "$(dirname "$0")"
STAMP=$(date +%Y%m%d-%H%M%S)
install_dir() {
  local src="$1" dst="$2" f
  mkdir -p "$dst"
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    if [ -e "$dst/$(basename "$f")" ]; then
      cp -p "$dst/$(basename "$f")" "$dst/$(basename "$f").bak-$STAMP"
      echo "backup: $dst/$(basename "$f").bak-$STAMP"
    fi
    cp "$f" "$dst/"
    echo "installed: $dst/$(basename "$f")"
  done
}
install_dir bin "$HOME/.claude/bin"
chmod +x "$HOME/.claude/bin/"*.sh "$HOME/.claude/bin/"*.js 2>/dev/null || true
install_dir commands "$HOME/.claude/commands"
[ -f "$HOME/.claude/strata.env" ] || echo "Note: create ~/.claude/strata.env (see strata.env.example)"
