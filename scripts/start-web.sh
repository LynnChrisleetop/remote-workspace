#!/usr/bin/env bash
#
# Standalone launcher: start (or reuse) `dsh web` on the machine you are on,
# then print a tokenized URL.
#
#   ./start-web.sh              # port from dsh-remote.env, else 8787
#   ./start-web.sh 9000
#
# `install-remote.sh` writes an equivalent file next to its own prefix; this
# copy exists for people who want to wire things up by hand.
#
# It reads dsh-remote.env from the same directory when present:
#
#   DSH_NODE_BIN=/path/to/node/bin
#   DSH_BIN=/path/to/dsh/bin/dsh
#   DSH_HOME=/path/to/dsh-home
#   DSH_WORKSPACE=/path/to/workspace
#   DSH_WEB_PORT=8787
#
# NOTE: install-remote.sh embeds a copy of this file. Keep both in sync.
set -u
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
[ -f "$SELF_DIR/dsh-remote.env" ] && . "$SELF_DIR/dsh-remote.env"

PORT_DEFAULT="${DSH_WEB_PORT:-8787}"
DSH_BIN="${DSH_BIN:-$SELF_DIR/dsh/bin/dsh}"
NODE_BIN_DIR="${DSH_NODE_BIN:-$SELF_DIR/node/bin}"
DSH_HOME="${DSH_HOME:-$SELF_DIR/dsh-home}"
WORKDIR="${DSH_WORKSPACE:-$HOME}"

[ -d "$NODE_BIN_DIR" ] && export PATH="$NODE_BIN_DIR:$PATH"
export DSH_HOME
mkdir -p "$DSH_HOME" 2>/dev/null || true

FOREGROUND=0
if [ "${1:-}" = "--foreground" ]; then FOREGROUND=1; shift; fi
PORT="${1:-$PORT_DEFAULT}"
LOG="${DSH_LOG:-/tmp/dsh-web-${PORT}.log}"

if [ "$FOREGROUND" -eq 1 ]; then
  cd "$WORKDIR" || exit 1
  exec "$DSH_BIN" web --port "$PORT"
fi

port_busy() {
  { ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true; } | grep -q "127.0.0.1:${PORT} "
}

if port_busy; then
  echo "dsh web already listening on $PORT, reusing it" >&2
else
  : > "$LOG" 2>/dev/null || true
  CMD="bash $(printf %q "$SELF_DIR/start-web.sh") --foreground $PORT"
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "dsh-web-$PORT" 2>/dev/null || true
    tmux new-session -d -s "dsh-web-$PORT" "$CMD > $(printf %q "$LOG") 2>&1"
  else
    setsid bash -c "$CMD > $(printf %q "$LOG") 2>&1" </dev/null >/dev/null 2>&1 &
  fi
fi

URL=""
i=0
while [ "$i" -lt 60 ]; do
  URL=$(grep -o "http://127\.0\.0\.1:${PORT}/?token=[A-Za-z0-9_-]*" "$LOG" 2>/dev/null | tail -1 || true)
  [ -n "$URL" ] && break
  i=$((i + 1))
  sleep 2
done

if [ -z "$URL" ]; then
  echo "timed out waiting for dsh web on port $PORT; last log lines:" >&2
  tail -20 "$LOG" >&2 2>/dev/null || true
  exit 1
fi

printf '%s\n' "$URL"
