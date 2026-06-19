#!/usr/bin/env bash
# PostToolUse hook: format edited shell scripts with shfmt when available.
# Reads the hook JSON payload on stdin and formats the touched file in place.
# No-ops gracefully if shfmt isn't installed or the file isn't a shell script,
# so a missing formatter never blocks an edit.
set -euo pipefail

command -v shfmt >/dev/null 2>&1 || exit 0

# The PostToolUse payload includes the edited path at .tool_input.file_path.
# Fall back to a no-op if we can't extract it (e.g. jq missing).
command -v jq >/dev/null 2>&1 || exit 0
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file" ] && [ -f "$file" ] || exit 0

case "$file" in
  *.sh) shfmt -w -i 2 -ci "$file" ;;
  *)
    # Format extensionless files only if they declare a shell shebang.
    head -n1 "$file" | grep -qE '^#!.*\b(sh|bash)\b' && shfmt -w -i 2 -ci "$file" || true
    ;;
esac
