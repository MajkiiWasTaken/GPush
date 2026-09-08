#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="3.2.0"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

CONFIG_DIR="$CONFIG_HOME/gpush"
CACHE_DIR="$CACHE_HOME/gpush"

CONFIG_FILE="$CONFIG_DIR/config"
CACHE_FILE="$CACHE_DIR/repos"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/gp"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/gp"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_MAGENTA=$'\033[35m'
  C_GRAY=$'\033[90m'
else
  C_RESET=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_MAGENTA=""
  C_GRAY=""
fi

printf '\n%sGPush installer %s%s%s\n' "$C_CYAN" "$C_GRAY" "$SCRIPT_VERSION" "$C_RESET"
printf '%sMade by %s%sMichal Švrček%s\n\n' "$C_GRAY" "$C_RESET" "$C_MAGENTA" "$C_RESET"

if ! command -v git >/dev/null 2>&1; then
  printf '%sGit was not found in PATH.%s\n' "$C_YELLOW" "$C_RESET"
  exit 1
fi

if [[ ! -f "$SOURCE" ]]; then
  printf '%sCould not find gp next to install.sh:%s %s\n' "$C_YELLOW" "$C_RESET" "$SOURCE"
  exit 1
fi

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CACHE_DIR"
install -m 0755 "$SOURCE" "$TARGET"

printf '%sInstalled:%s %s\n' "$C_GREEN" "$C_RESET" "$TARGET"

if [[ ! -f "$CONFIG_FILE" ]]; then
  printf '\nRepository search roots are stored one per line.\n'
  printf 'Default: %s\n\n' "$HOME/Projects"
  read -r -p "Search root [$HOME/Projects]: " SEARCH_ROOT
  SEARCH_ROOT="${SEARCH_ROOT:-$HOME/Projects}"

  printf '%s\n' "$SEARCH_ROOT" > "$CONFIG_FILE"
  printf '%sCreated config:%s %s\n' "$C_GREEN" "$C_RESET" "$CONFIG_FILE"
else
  printf '%sUsing existing config:%s %s\n' "$C_GREEN" "$C_RESET" "$CONFIG_FILE"
fi

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  SHELL_RC=""

  case "${SHELL:-}" in
    */zsh) SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
  esac

  if [[ -n "$SHELL_RC" ]]; then
    LINE='export PATH="$HOME/.local/bin:$PATH"'

    if [[ ! -f "$SHELL_RC" ]] || ! grep -Fqx "$LINE" "$SHELL_RC"; then
      printf '\n%s\n' '# GPush' >> "$SHELL_RC"
      printf '%s\n' "$LINE" >> "$SHELL_RC"
      printf '%sAdded ~/.local/bin to PATH in:%s %s\n' "$C_GREEN" "$C_RESET" "$SHELL_RC"
    fi

    printf '%sReload your shell or run:%s source %s\n' "$C_YELLOW" "$C_RESET" "$SHELL_RC"
  else
    printf '%s~/.local/bin is not currently in PATH.%s\n' "$C_YELLOW" "$C_RESET"
    printf 'Add this to your shell config:\n'
    printf '  export PATH="$HOME/.local/bin:$PATH"\n'
  fi
fi

printf '\nRefreshing repository cache...\n'
"$TARGET" --refresh || true

printf '\n%sGPush installation complete.%s\n' "$C_GREEN" "$C_RESET"
printf 'Run: gp --help\n\n'
