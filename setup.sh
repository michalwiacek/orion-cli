#!/usr/bin/env sh
set -eu

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
ORION_BIN="$BIN_DIR/orion"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER="# orion-cli-path"

ensure_path_line() {
  rc_file="$1"
  [ -f "$rc_file" ] || touch "$rc_file"

  if grep -Fq "$MARKER" "$rc_file" 2>/dev/null; then
    return
  fi

  if grep -Fq "$PATH_LINE" "$rc_file" 2>/dev/null; then
    return
  fi

  {
    printf "\n%s\n" "$MARKER"
    printf "%s\n" "$PATH_LINE"
  } >>"$rc_file"
}

echo "Installing orion to $PREFIX ..."
zig build install --prefix "$PREFIX"

if [ ! -x "$ORION_BIN" ]; then
  echo "Install failed: $ORION_BIN not found"
  exit 1
fi

if printf '%s' ":$PATH:" | grep -Fq ":$BIN_DIR:"; then
  echo "PATH already contains $BIN_DIR"
else
  ensure_path_line "$HOME/.zprofile"
  ensure_path_line "$HOME/.zshrc"
  ensure_path_line "$HOME/.bash_profile"
  ensure_path_line "$HOME/.bashrc"
  echo "Added $BIN_DIR to shell startup files (if present)."
fi

echo "Done. Verify with:"
echo "  $ORION_BIN --help"
echo "If 'orion' is still not found, open a new terminal or run:"
echo "  source ~/.zprofile"
