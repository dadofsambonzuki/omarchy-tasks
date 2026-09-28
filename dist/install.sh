#!/usr/bin/env bash
# Build and install Tasks for the current user: the omarchy-taskbridge
# helper in ~/.local/bin and, from a checkout outside Omarchy's plugin
# folder, a link to this checkout in ~/.config/omarchy/plugins.
#
#   ./dist/install.sh                 build with cargo and install
#   ./dist/install.sh --no-build      install an already-built helper
#   ./dist/install.sh --replace-existing
#                                     consent to move aside a file at the
#                                     helper path that this plugin did not
#                                     write (it is kept as a backup)
#
# The helper path is only ever written when it is empty or holds a file
# this plugin installed (its SHA-256 is recorded in
# $XDG_STATE_HOME/omarchy-tasks/installed.tsv). Anything else is refused,
# or moved to a backup with --replace-existing. Nothing is executed to
# decide that, and no elevated permissions are used.
# Run it again after `git pull` / `omarchy plugin update` to update.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
PLUGIN_ID="derekross.tasks"
HELPER="omarchy-taskbridge"
BINDIR="$HOME/.local/bin"
DEST="$BINDIR/$HELPER"
PLUGINDIR="$HOME/.config/omarchy/plugins"
PLUGIN_PATH="$PLUGINDIR/$PLUGIN_ID"
STATEDIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tasks"
RECORD="$STATEDIR/installed.tsv"
BACKUPDIR="$STATEDIR/backup"

BUILD=1
REPLACE=0
for arg in "$@"; do
  case $arg in
    --no-build) BUILD=0 ;;
    --replace-existing) REPLACE=1 ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

[[ -f manifest.json && -d crates/taskbridge ]] || { echo "Run this from an omarchy-tasks checkout." >&2; exit 1; }
command -v task >/dev/null || echo "Note: Taskwarrior (task) is not installed; the plugin will say so until it is. It is the task package in your distribution."

sha() { sha256sum -- "$1" | cut -d' ' -f1; }
recorded_sha() { [[ -f "$RECORD" ]] && awk -F'\t' -v p="$DEST" '$2 == p { print $1 }' "$RECORD" | tail -1 || true; }

# ── Is the destination ours? Decided from bytes and the record, never by
#    running what is there.
case "$(if [[ -L $DEST ]]; then echo link; elif [[ ! -e $DEST ]]; then echo missing; elif [[ -f $DEST ]]; then echo file; else echo other; fi)" in
  missing) ;;
  file)
    if [[ "$(sha "$DEST")" != "$(recorded_sha)" ]]; then
      if (( REPLACE )); then
        mkdir -p "$BACKUPDIR"
        backup="$BACKUPDIR/$HELPER.$(date +%Y%m%d-%H%M%S)"
        mv -- "$DEST" "$backup"
        echo "Moved the existing $DEST (not written by this plugin) to $backup"
      else
        echo "Refusing to overwrite $DEST: this plugin has no record of writing it." >&2
        echo "If it is yours to replace, run again with --replace-existing (the file is kept as a backup)." >&2
        exit 1
      fi
    fi ;;
  link | other)
    echo "Refusing to write $DEST: it is a link or not a regular file. Remove it yourself first." >&2
    exit 1 ;;
esac

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
[[ -f "$BIN" && -x "$BIN" ]] || { echo "No helper at $BIN; build first" >&2; exit 1; }

mkdir -p "$BINDIR" "$STATEDIR"
install -m755 -- "$BIN" "$DEST"
# The record: one "<sha256>\t<path>" line per file this plugin wrote.
{ [[ -f "$RECORD" ]] && awk -F'\t' -v p="$DEST" '$2 != p' "$RECORD" || true; printf '%s\t%s\n' "$(sha "$DEST")" "$DEST"; } > "$RECORD.tmp"
mv -- "$RECORD.tmp" "$RECORD"
echo "Installed $DEST"

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
