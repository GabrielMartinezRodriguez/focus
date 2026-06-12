#!/bin/bash
# Recompila focus e instala el comando CLI y la app de barra de menú.
set -e
cd "$(dirname "$0")"

echo "▸ Compilando…"
swift build -c release

# 1. Comando CLI: symlink (se actualiza solo en cada build)
mkdir -p ~/bin
ln -sf "$PWD/.build/release/focus" ~/bin/focus
echo "✓ Comando 'focus' → ~/bin/focus"

# 2. App de barra de menú: copiar el binario fresco al bundle y refirmar
APP=~/Applications/FocusBar.app
if [ -d "$APP" ]; then
  pkill -x FocusBar 2>/dev/null || true
  sleep 1
  cp .build/release/FocusBar "$APP/Contents/MacOS/FocusBar"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  open "$APP"
  echo "✓ FocusBar.app actualizada y relanzada"
else
  echo "ℹ FocusBar.app no instalada (solo CLI). Mira el README para crear el bundle."
fi

case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) echo "⚠ Añade ~/bin a tu PATH:  echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "Listo."
