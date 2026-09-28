#!/usr/bin/env bash
# Remove Tasks: the omarchy-taskbridge helper and the plugin link. Only
# what this plugin wrote is removed. The helper is deleted only if it is a
# regular file whose SHA-256 matches the install record; nothing at that
# path is ever executed to decide. The link is removed only if it points
# at this checkout. Your Taskwarrior data is untouched.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
PLUGIN_ID="derekross.tasks"
DEST="$HOME/.local/bin/omarchy-taskbridge"
PLUGIN_PATH="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
STATEDIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tasks"
RECORD="$STATEDIR/installed.tsv"

omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true

recorded=""
if [[ -L "$STATEDIR" || -L "$RECORD" ]]; then
  echo "Left the install record alone: $STATEDIR or $RECORD is a link, which this plugin never writes." >&2
elif [[ -f "$RECORD" ]]; then
  recorded="$(awk -F'\t' -v p="$DEST" '$2 == p { print $1 }' "$RECORD" | tail -1)"
fi
if [[ -L "$DEST" ]]; then
  echo "Left $DEST alone: it is a link, which this plugin never writes."
elif [[ -f "$DEST" ]]; then
  if [[ -n "$recorded" && "$(sha256sum -- "$DEST" | cut -d' ' -f1)" == "$recorded" ]]; then
    rm -f -- "$DEST" && echo "Removed $DEST"
  else
    echo "Left $DEST alone: it is not the file this plugin installed (no matching record)."
  fi
fi
if [[ -f "$RECORD" && ! -L "$RECORD" && ! -L "$STATEDIR" ]]; then
  tmp="$(mktemp -- "$STATEDIR/installed.tsv.XXXXXX")"
  awk -F'\t' -v p="$DEST" '$2 != p' "$RECORD" > "$tmp" || true
  if [[ -s "$tmp" ]]; then mv -f -- "$tmp" "$RECORD"; else rm -f -- "$tmp" "$RECORD"; fi
fi

if [[ -L "$PLUGIN_PATH" ]]; then
  if [[ "$(realpath -m "$PLUGIN_PATH")" == "$REPO" ]]; then
    rm -- "$PLUGIN_PATH" && echo "Removed link $PLUGIN_PATH"
  else
    echo "Left $PLUGIN_PATH alone: it points somewhere else."
  fi
elif [[ -d "$PLUGIN_PATH" ]]; then
  echo "Plugin checkout at $PLUGIN_PATH left in place; remove it with: omarchy plugin remove $PLUGIN_ID"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
