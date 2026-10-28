#!/usr/bin/env bash
#
# Connect to the DSH instance running on your remote machine.
#
#   ./connect.sh --host my-devbox
#   ./connect.sh --host my-devbox --local-port 9000
#   ./connect.sh --host devbox --no-open
#
# It does three things:
#   1. starts (or reuses) `dsh web` on the remote
#   2. opens an SSH tunnel  localhost:<local-port> -> remote 127.0.0.1:<remote-port>
#   3. opens the tokenized URL in your browser
#
# Requires: nothing on the remote beyond what install-remote.sh set up.
set -euo pipefail

HOST=""; SSH_PORT=""; SSH_USER=""; SSH_KEY=""
LOCAL_PORT=8787; REMOTE_PORT=8787
REMOTE_SCRIPT='$HOME/.dsh-remote-workspace/start-web.sh'
DO_OPEN=1

say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Connect to a remote DSH instance over an SSH tunnel.

Usage: connect.sh --host <ssh-alias-or-ip> [options]

  --host <h>            SSH alias / hostname / IP (required)
  --ssh-port <n>        SSH port
  --user <u>            SSH user
  --key <path>          SSH private key
  --local-port <n>      Local tunnel port (default 8787)
  --remote-port <n>     Remote `dsh web` port (default 8787)
  --remote-script <p>   Path to start-web.sh on the remote
                        (default: $HOME/.dsh-remote-workspace/start-web.sh)
  --no-open             Do not launch a browser
  -h, --help            This help
EOF
}

need_val() { [ $# -ge 2 ] && [ -n "${2:-}" ] || { printf 'error: %s needs a value\n' "$1" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)          need_val "$@"; HOST="$2"; shift 2 ;;
    --ssh-port)      need_val "$@"; SSH_PORT="$2"; shift 2 ;;
    --user)          need_val "$@"; SSH_USER="$2"; shift 2 ;;
    --key)           need_val "$@"; SSH_KEY="$2"; shift 2 ;;
    --local-port)    need_val "$@"; LOCAL_PORT="$2"; shift 2 ;;
    --remote-port)   need_val "$@"; REMOTE_PORT="$2"; shift 2 ;;
    --remote-script) need_val "$@"; REMOTE_SCRIPT="$2"; shift 2 ;;
    --no-open)       DO_OPEN=0; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'error: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 2; }

TARGET="$HOST"
[ -n "$SSH_USER" ] && TARGET="$SSH_USER@$HOST"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_PORT" ] && SSH_OPTS+=(-p "$SSH_PORT")
[ -n "$SSH_KEY" ]  && SSH_OPTS+=(-i "$SSH_KEY")

port_open() {
  local p="$1"
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$p" >/dev/null 2>&1 && return 0; fi
  if command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0; fi
  (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 && return 0
  return 1
}

# Read DSH_WORKSPACE out of the remote dsh-remote.env (best effort, cosmetic).
remote_workspace() {
  local body b64
  body=$(cat <<'RS'
f="$1"; d=$(dirname "$f")
[ -f "$d/dsh-remote.env" ] && . "$d/dsh-remote.env"
printf '%s' "${DSH_WORKSPACE:-}"
RS
)
  b64=$(printf '%s' "$body" | base64 | tr -d '\n')
  ssh "${SSH_OPTS[@]}" "$TARGET" "echo $b64 | base64 -d | bash -s -- $(printf '%q' "$REMOTE_SCRIPT")" 2>/dev/null || true
}

# 1) ask the remote to make sure `dsh web` is up, and hand us its URL
info "asking $TARGET to start (or reuse) dsh web"
URL=$(ssh "${SSH_OPTS[@]}" "$TARGET" "bash $REMOTE_SCRIPT $REMOTE_PORT" 2>/dev/null \
      | grep -o "http://127\.0\.0\.1:${REMOTE_PORT}/?token=[A-Za-z0-9_-]*" | tail -1 || true)

if [ -z "$URL" ]; then
  printf '\033[31merror:\033[0m could not get a URL from the remote.\n' >&2
  echo "  Check that the install exists:" >&2
  echo "    ssh $TARGET 'ls -l $REMOTE_SCRIPT'" >&2
  echo "  or run the installer again:  ./install-remote.sh --host $HOST" >&2
  exit 1
fi

# 2) tunnel
if port_open "$LOCAL_PORT"; then
  info "localhost:$LOCAL_PORT already listening, reusing the tunnel"
else
  info "opening tunnel localhost:$LOCAL_PORT -> $TARGET:127.0.0.1:$REMOTE_PORT"
  ssh -f -N "${SSH_OPTS[@]}" -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "$TARGET"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port_open "$LOCAL_PORT" && break
    sleep 0.5
  done
  port_open "$LOCAL_PORT" || die "tunnel did not come up on port $LOCAL_PORT"
fi

LOCAL_URL="$URL"
if [ "$LOCAL_PORT" != "$REMOTE_PORT" ]; then
  LOCAL_URL=$(printf '%s' "$URL" | sed "s/:${REMOTE_PORT}\//:${LOCAL_PORT}\//")
fi

WS=$(remote_workspace)
say ""
say "  remote workspace : ${WS:-(unknown)}"
say "  open             : $LOCAL_URL"
say ""

if [ "$DO_OPEN" -eq 1 ]; then
  case "$(uname -s)" in
    Darwin) open "$LOCAL_URL" 2>/dev/null || true ;;
    Linux)  xdg-open "$LOCAL_URL" >/dev/null 2>&1 || true ;;
    *)      : ;;
  esac
fi

say "Leave the tunnel running. To close it: kill the ssh -N process, or reboot."
