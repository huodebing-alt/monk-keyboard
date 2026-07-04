#!/bin/bash
# Per-user install of the Comp input method (no admin rights needed).
# Usage: unzip Comp-*.zip && ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Input Methods"
mkdir -p "$DEST"

# clear the quarantine flag so Gatekeeper lets the input method launch
xattr -dr com.apple.quarantine "$HERE/Comp.app" 2>/dev/null || true

rm -rf "$DEST/Comp.app"
cp -R "$HERE/Comp.app" "$DEST/"

# nudge the text input system to notice the new input source
pkill -f Comp.app 2>/dev/null || true

cat <<'EOF'

Comp is installed. To activate it:

  1. Open System Settings -> Keyboard -> Text Input -> Input Sources -> Edit
  2. Click "+", choose English (or your language), select "Comp", click Add
  3. Switch to Comp with the input menu (or Ctrl+Space)

If Comp does not appear in the list, log out and log back in once.

Type letter chords (press the key letters of a word together) and hit
space -- Comp fills in the word. See https://github.com/huodebing-alt/comp-keyboard
EOF
