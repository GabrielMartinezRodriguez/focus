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
  # Firma con identidad estable si existe (así Acceso total al disco sobrevive a recompilados);
  # si no, ad-hoc. Puedes fijarla con: export FOCUS_SIGN_IDENTITY="Apple Development: ..."
  IDENTITY="${FOCUS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
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
