#!/usr/bin/env bash
# Remove Tasks: the omarchy-taskbridge helper and the plugin link. Only
# what this plugin put there is removed: the helper is checked to be ours
# before deletion, and the link only if it points at this checkout. Your
# Taskwarrior data is untouched.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
PLUGIN_ID="derekross.tasks"
HELPER="$HOME/.local/bin/omarchy-taskbridge"
PLUGIN_PATH="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true

if [[ -f "$HELPER" && ! -L "$HELPER" ]]; then
  if "$HELPER" version 2>/dev/null | grep -q '"taskbridge"'; then
    rm -f -- "$HELPER" && echo "Removed $HELPER"
  else
    echo "Left $HELPER alone: it doesn't answer as this plugin's helper."
  fi
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
