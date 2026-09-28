#!/usr/bin/env bash
# Build and install Tasks for the current user: the omarchy-taskbridge
# helper in ~/.local/bin and, from a checkout outside Omarchy's plugin
# folder, a link to this checkout in ~/.config/omarchy/plugins.
#
#   ./dist/install.sh            build with cargo and install
#   ./dist/install.sh --no-build install an already-built helper
#
# It writes only those two paths and never asks for elevated permissions.
# Run it again after `git pull` / `omarchy plugin update` to update.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
PLUGIN_ID="derekross.tasks"
HELPER="omarchy-taskbridge"
BINDIR="$HOME/.local/bin"
PLUGINDIR="$HOME/.config/omarchy/plugins"
PLUGIN_PATH="$PLUGINDIR/$PLUGIN_ID"

BUILD=1
for arg in "$@"; do
  case $arg in
    --no-build) BUILD=0 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ -f manifest.json && -d crates/taskbridge ]] || { echo "Run this from an omarchy-tasks checkout." >&2; exit 1; }
command -v task >/dev/null || echo "Note: Taskwarrior (task) is not installed; the plugin will say so until it is. It is the task package in your distribution."

# Installed with `omarchy plugin add`, this checkout is the plugin; build
# outside it so the shell doesn't reload on every object file.
if [[ "$REPO" == "$(realpath -m "$PLUGIN_PATH")" ]]; then
  export CARGO_TARGET_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-tasks/target"
fi

if (( BUILD )); then
  command -v cargo >/dev/null || { echo "cargo is needed to build the helper: install the Rust toolchain (rustup), then run rustup default stable" >&2; exit 1; }
  echo "Building $HELPER…"
  cargo build --release --locked --quiet
fi

BIN="${CARGO_TARGET_DIR:-$REPO/target}/release/$HELPER"
[[ -x "$BIN" ]] || { echo "No helper at $BIN; build first" >&2; exit 1; }
install -Dm755 "$BIN" "$BINDIR/$HELPER"
echo "Installed $BINDIR/$HELPER"

if [[ ! -e "$PLUGIN_PATH" && ! -L "$PLUGIN_PATH" ]]; then
  mkdir -p "$PLUGINDIR"
  ln -s "$REPO" "$PLUGIN_PATH"
  echo "Linked $PLUGIN_PATH -> $REPO"
elif [[ "$(realpath -m "$PLUGIN_PATH")" != "$REPO" ]]; then
  echo "Note: $PLUGIN_PATH exists and is not this checkout; leaving it alone."
fi

if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi
echo
echo "Now enable it and put it on the bar:"
echo "  omarchy plugin enable $PLUGIN_ID"
echo "  omarchy bar move $PLUGIN_ID --section right"
