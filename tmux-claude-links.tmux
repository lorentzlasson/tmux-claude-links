#!/usr/bin/env bash

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

option() {
  local value
  value="$(tmux show -gqv "$1")"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

if command -v tmux-claude-links >/dev/null 2>&1; then
  binary="$(command -v tmux-claude-links)"
else
  binary="$here/zig-out/bin/tmux-claude-links"
fi

if [ ! -x "$binary" ]; then
  tmux display-message "tmux-claude-links: not built yet, run 'just build'"
  exit 1
fi

key="$(option '@claude-links-bind' 'o')"

tmux bind-key "$key" run-shell -b "'$binary' '#{pane_id}'"
