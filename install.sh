#!/bin/bash
# Recompila focus e instala el comando CLI y la app de barra de menú.
set -e
cd "$(dirname "$0")"

echo "▸ Compilando…"
swift build -c release

# Identidad de firma estable (permite conceder Acceso total al disco una sola vez)
IDENTITY="${FOCUS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"

# 1. Comando CLI: copia firmada (no symlink: la firma estable requiere binario propio)
mkdir -p ~/bin
rm -f ~/bin/focus
cp .build/release/focus ~/bin/focus
codesign --force --identifier es.feynman.focus.cli --sign "${IDENTITY:--}" ~/bin/focus >/dev/null 2>&1 || true
echo "✓ Comando 'focus' → ~/bin/focus (copia firmada)"

# 2. App de barra de menú: copiar el binario fresco al bundle y refirmar
APP=~/Applications/FocusBar.app
if [ -d "$APP" ]; then
  pkill -x FocusBar 2>/dev/null || true
  sleep 1
  cp .build/release/FocusBar "$APP/Contents/MacOS/FocusBar"
  codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || \
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
