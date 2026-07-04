#!/bin/bash
# Per-user install of the Monk input method (no admin rights needed).
# Usage: unzip Monk-*.zip && ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Input Methods"
mkdir -p "$DEST"

# clear the quarantine flag so Gatekeeper lets the input method launch
xattr -dr com.apple.quarantine "$HERE/Monk.app" 2>/dev/null || true

rm -rf "$DEST/Monk.app"
cp -R "$HERE/Monk.app" "$DEST/"

# retire the old name, if a previous Comp install is present
if [ -d "$DEST/Comp.app" ]; then
  rm -rf "$DEST/Comp.app"
  echo "(removed previous Comp.app install)"
fi
# carry personalization over from a Comp-era install
if [ -d "$HOME/Library/Application Support/Comp" ] && \
   [ ! -d "$HOME/Library/Application Support/Monk" ]; then
  cp -R "$HOME/Library/Application Support/Comp" "$HOME/Library/Application Support/Monk"
  echo "(migrated settings from Comp)"
fi

# stop any old instance, then register the input source with the system so
# it shows up in System Settings immediately (no log out needed)
pkill -f Monk.app 2>/dev/null || true
pkill -f Comp.app 2>/dev/null || true
if [ -x "$HERE/monk-register" ]; then
  xattr -d com.apple.quarantine "$HERE/monk-register" 2>/dev/null || true
  "$HERE/monk-register" "$DEST/Monk.app" || true
fi

cat <<'EOF'

Monk is installed. To activate it:

  1. Open System Settings -> Keyboard -> Text Input -> Input Sources -> Edit
  2. Click "+", choose English (or your language), select "Monk", click Add
  3. Switch to Monk with the input menu (or Ctrl+Space)

If Monk does not appear in the list, log out and log back in once.

Press a word's key letters together (A+P+L), hit space -- Monk fills in
"apple". See https://github.com/huodebing-alt/monk-keyboard
EOF
