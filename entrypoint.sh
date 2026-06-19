#!/bin/sh
set -e

# machine-id should be unique per container, so generate it on every start.
# (Baking it at build time would give every container the same ID.)
# /etc/machine-id is resonite-owned at build time, so the non-root user can write it.
tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id

# Resonite writes into its install directory (logs, etc.), so it can't run from a
# read-only mount. rsync the host's install (/resonite, ro) into a writable volume
# (APP_DIR) and run from there. The host install is never modified.
#
# APP_DIR stays outside HOME (/opt). HOME (/home/resonite) is a named-volume mount
# point, so an install under it makes umu treat the parent mount as the S: gamedrive,
# the CWD's current drive becomes S:, and absolute paths (/dev/shm, ...) misresolve.
# Under /opt the install's parent is not a mount, so CWD is Z: (-> /) and resolves right.
#
# rsync diffs by size+mtime and transfers only changed files (full copy on first run,
# only updates/MODs after). --delete tracks host-side deletions; --itemize-changes
# reports only what actually changed (nothing if there's no diff).
APP_DIR=/opt/resonite
mkdir -p "$APP_DIR"
echo "syncing Resonite -> $APP_DIR (rsync; first run copies ~2GB)..."
changed="$(rsync -a --delete --itemize-changes /resonite/ "$APP_DIR/")"
if [ -z "$changed" ]; then
  echo "no changes; $APP_DIR is up to date."
else
  n=$(printf '%s\n' "$changed" | wc -l)
  [ "$n" -le 20 ] && printf '%s\n' "$changed" | sed 's/^/  /'
  echo "synced $n changed item(s) -> $APP_DIR"
fi

# ResoBoot reads/writes game files relative to CWD, so cd into the copy. Because
# APP_DIR (/opt/resonite) is outside HOME, CWD's current drive is Z: (-> /), so the
# absolute Unix paths ResoBoot/the renderer pass (/dev/shm, /opt/resonite/Renderer, ...)
# resolve correctly. This also lets the engine<->ResoBoot shared-memory IPC (Cloudtoid)
# agree on the same /dev/shm, so the renderer can start (same behavior as on the host).
cd "$APP_DIR"

exec "$@"
