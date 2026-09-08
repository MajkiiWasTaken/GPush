#!/usr/bin/env bash
set -euo pipefail

INSTALLER_VERSION="4.0.1"
AUTHOR="Michal Švrček"
GITHUB="https://github.com/MajkiiWasTaken"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
CONFIG_DIR="$CONFIG_HOME/gpush"
CACHE_DIR="$CACHE_HOME/gpush"
CONFIG_FILE="$CONFIG_DIR/config"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/gp"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/gp"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_MAGENTA=$'\033[35m'; C_GRAY=$'\033[90m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_MAGENTA=""; C_GRAY=""; C_RED=""
fi

printf '\n%sGPush installer %s%s%s\n' "$C_CYAN" "$C_GRAY" "$INSTALLER_VERSION" "$C_RESET"
printf '%sMade by %s%s%s%s\n' "$C_GRAY" "$C_RESET" "$C_MAGENTA" "$AUTHOR" "$C_RESET"
printf '%sGitHub  %s%s\n\n' "$C_GRAY" "$GITHUB" "$C_RESET"

if ! command -v git >/dev/null 2>&1; then
  printf '%sGit was not found in PATH.%s\n' "$C_RED" "$C_RESET" >&2
  exit 1
fi
printf '%sGit detected:%s %s\n' "$C_GREEN" "$C_RESET" "$(git --version)"

if [[ ! -f "$SOURCE" ]]; then
  printf '%sCould not find gp next to install.sh:%s %s\n' "$C_RED" "$C_RESET" "$SOURCE" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CACHE_DIR"
install -m 0755 "$SOURCE" "$TARGET"
printf '%sInstalled:%s %s\n' "$C_GREEN" "$C_RESET" "$TARGET"

# Preserve an existing v4 config. Otherwise create a simple portable config.
if [[ ! -f "$CONFIG_FILE" ]]; then
  default_root=""
  for candidate in "$HOME/Projects" "$HOME/Documents/Project" "$HOME/Documents/Projects" "$HOME/Documents"; do
    if [[ -d "$candidate" ]]; then default_root="$candidate"; break; fi
  done
  default_root="${default_root:-$HOME/Projects}"

  printf '\nRepository search root.\nDefault: %s\n\n' "$default_root"
  read -r -p "Search root [$default_root]: " search_root
  search_root="${search_root:-$default_root}"
  search_root="${search_root/#\~/$HOME}"

  if [[ ! -d "$search_root" ]]; then
    read -r -p "Directory does not exist. Create it? [y/N] " create
    if [[ "$create" =~ ^([yY]|[yY][eE][sS])$ ]]; then mkdir -p "$search_root"; else printf '%sInstallation cancelled.%s\n' "$C_YELLOW" "$C_RESET"; exit 1; fi
  fi

  cat > "$CONFIG_FILE" <<CFG
# GPush 4.x Linux configuration
# Add more search_root= lines when needed.
search_root=$search_root
default_remote=origin
large_file_mb=25
CFG
  printf '%sCreated config:%s %s\n' "$C_GREEN" "$C_RESET" "$CONFIG_FILE"
else
  printf '%sUsing existing config:%s %s\n' "$C_GREEN" "$C_RESET" "$CONFIG_FILE"
fi

# Ensure ~/.local/bin is available in common shells without duplicating entries.
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  shell_rc=""
  case "${SHELL:-}" in
    */zsh) shell_rc="$HOME/.zshrc" ;;
    */bash) shell_rc="$HOME/.bashrc" ;;
  esac

  if [[ -n "$shell_rc" ]]; then
    line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    if [[ ! -f "$shell_rc" ]] || ! grep -Fqx "$line" "$shell_rc"; then
      { printf '\n# GPush\n'; printf '%s\n' "$line"; } >> "$shell_rc"
      printf '%sAdded ~/.local/bin to PATH in:%s %s\n' "$C_GREEN" "$C_RESET" "$shell_rc"
    fi
    printf '%sReload your shell or run:%s source %s\n' "$C_YELLOW" "$C_RESET" "$shell_rc"
  else
    printf '%s~/.local/bin is not in PATH.%s\n' "$C_YELLOW" "$C_RESET"
    printf "Add: export PATH=\"\$HOME/.local/bin:\$PATH\"\n"
  fi
fi

# Force a fresh cache after upgrades, then run a lightweight sanity check.
rm -f "$CACHE_DIR/repos"
printf '\nRefreshing repository cache...\n'
"$TARGET" cache refresh || true

printf '\n%sGPush installation complete.%s\n' "$C_GREEN" "$C_RESET"
printf 'Try:\n'
printf '  gp version\n'
printf '  gp help\n'
printf '  gp config doctor\n\n'
