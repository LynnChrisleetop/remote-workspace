#!/usr/bin/env bash
#
# dsh-remote-workspace installer
#
# Installs DeepSeek Harness (dsh) on a remote machine over SSH, wires up a
# workspace, starts `dsh web` (loopback only) and prints a tokenized URL that
# you open locally through an SSH tunnel.
#
# The point: the agent, the workspace and the conversation history all live on
# the remote machine, so any computer that can SSH there sees the same
# workspaces and the same history.
#
# Usage:
#   ./install-remote.sh --host my-devbox
#   ./install-remote.sh --host 203.0.113.10 --port 2222 --user root --workspace /data/proj
#   curl -fsSL <raw-url>/install-remote.sh | bash -s -- --host my-devbox
#
# Run `./install-remote.sh --help` for all flags.
set -euo pipefail

DSH_VERSION_DEFAULT="0.2.1-rc.2"
NODE_VERSION_DEFAULT="24.9.0"
NODE_MIRROR_DEFAULT="https://registry.npmmirror.com/-/binary/node"
PREFIX_DEFAULT='$HOME/.dsh-remote-workspace'
WEB_PORT_DEFAULT="8787"

say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
dsh-remote-workspace — run DeepSeek Harness on a remote machine, share it across computers.

Usage:
  install-remote.sh --host <ssh-alias-or-ip> [options]

Required:
  --host <h>              SSH alias from ~/.ssh/config, or a hostname / IP.

SSH options:
  --port <n>              SSH port (default: 22, or whatever ~/.ssh/config says)
  --user <u>              SSH user (default: from ~/.ssh/config / current user)
  --key <path>            SSH private key path

Remote install options:
  --prefix <path>         Install root on the remote (default: $HOME/.dsh-remote-workspace)
  --workspace <path>      Directory to use as the workspace root (default: remote $HOME)
  --web-port <n>          Port `dsh web` listens on (loopback only, default 8787)
  --dsh-version <v>       @deepseek-ai/dsh version (default: 0.2.1-rc.2)
  --node-version <v>      Node.js version to install if needed (default: 24.9.0)
  --node-mirror <url>     Node.js download mirror (default: registry.npmmirror.com)
  --node-dir <path>       Reuse existing node >= 24: path to its bin/ directory
  --no-install-node       Fail instead of downloading Node.js
  --no-register-workspace Skip pre-registering the workspace record
  --dry-run               Print what would happen on the remote, change nothing

Exit codes:
  0  success (prints the tokenized URL on the last line)
  1  generic failure
  2  bad usage
EOF
}

# ---------------------------------------------------------------- arg parsing

HOST=""; SSH_PORT=""; SSH_USER=""; SSH_KEY=""
PREFIX="$PREFIX_DEFAULT"; WORKSPACE=""; WEB_PORT="$WEB_PORT_DEFAULT"
DSH_VERSION="$DSH_VERSION_DEFAULT"; NODE_VERSION="$NODE_VERSION_DEFAULT"
NODE_MIRROR="$NODE_MIRROR_DEFAULT"; NODE_DIR=""
INSTALL_NODE=1; REGISTER_WS=1; DRY_RUN=0

need_val() { [ $# -ge 2 ] && [ -n "${2:-}" ] || { printf 'error: %s needs a value\n' "$1" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)                need_val "$@"; HOST="$2"; shift 2 ;;
    --port|--ssh-port)     need_val "$@"; SSH_PORT="$2"; shift 2 ;;
    --user)                need_val "$@"; SSH_USER="$2"; shift 2 ;;
    --key)                 need_val "$@"; SSH_KEY="$2"; shift 2 ;;
    --prefix)              need_val "$@"; PREFIX="$2"; shift 2 ;;
    --workspace)           need_val "$@"; WORKSPACE="$2"; shift 2 ;;
    --web-port)            need_val "$@"; WEB_PORT="$2"; shift 2 ;;
    --dsh-version)         need_val "$@"; DSH_VERSION="$2"; shift 2 ;;
    --node-version)        need_val "$@"; NODE_VERSION="$2"; shift 2 ;;
    --node-mirror)         need_val "$@"; NODE_MIRROR="$2"; shift 2 ;;
    --node-dir)            need_val "$@"; NODE_DIR="$2"; shift 2 ;;
    --no-install-node)     INSTALL_NODE=0; shift ;;
    --no-register-workspace) REGISTER_WS=0; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) printf 'error: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 2; }

# ---------------------------------------------------------------- ssh plumbing

TARGET="$HOST"
if [ -n "$SSH_USER" ]; then TARGET="$SSH_USER@$HOST"; fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
if [ -n "$SSH_PORT" ]; then SSH_OPTS+=(-p "$SSH_PORT"); fi
if [ -n "$SSH_KEY" ];  then SSH_OPTS+=(-i "$SSH_KEY"); fi

# Run a static script on the remote via stdin (base64 avoids every quoting
# problem that plagues `ssh host "long command with quotes"`).
remote_script() {
  local script="$1"; shift || true
  local b64
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  local args=""
  if [ $# -gt 0 ]; then args=" $(printf '%q ' "$@")"; fi
  # shellcheck disable=SC2086
  ssh "${SSH_OPTS[@]}" "$TARGET" "echo $b64 | base64 -d | bash -s --$args"
}

info "checking SSH connectivity to $TARGET"
# shellcheck disable=SC2086
if ! ssh "${SSH_OPTS[@]}" "$TARGET" 'printf "ok %s %s\n" "$(uname -s)" "$(uname -m)"' >/dev/null 2>&1; then
  die "cannot SSH to $TARGET (try it manually: ssh $TARGET)"
fi
say "    connected."

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run: would install on $TARGET"
  say "    prefix      : $PREFIX"
  say "    workspace   : ${WORKSPACE:-<remote \$HOME>}"
  say "    dsh version : $DSH_VERSION"
  say "    node        : ${NODE_DIR:-$NODE_VERSION (install if missing)}"
  say "    web port    : $WEB_PORT"
  say "    register ws : $REGISTER_WS"
  exit 0
fi

# ---------------------------------------------------------------- remote body

# shellcheck disable=SC2016
REMOTE_BODY=$(cat <<'REMOTE'
set -euo pipefail

PREFIX="$1"; WORKSPACE="$2"; WEB_PORT="$3"; DSH_VERSION="$4"
NODE_VERSION="$5"; NODE_MIRROR="$6"; NODE_DIR="$7"
INSTALL_NODE="$8"; REGISTER_WS="$9"

# Expand a literal "$HOME" prefix that came from the local side.
PREFIX="${PREFIX//\$HOME/$HOME}"
WORKSPACE="${WORKSPACE//\$HOME/$HOME}"
[ -n "$WORKSPACE" ] || WORKSPACE="$HOME"
[ -d "$WORKSPACE" ] || { echo "warning: workspace $WORKSPACE does not exist yet; creating" >&2; mkdir -p "$WORKSPACE"; }

log()  { printf '\033[36m  ·\033[0m %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

log "prefix    : $PREFIX"
log "workspace : $WORKSPACE"
mkdir -p "$PREFIX"

# ---------------------------------------------------------------- node runtime
#
# We need Node >= 24: dsh's CLI entry ends with `if (import.meta.main) await
# runCli();` and `import.meta.main` only exists from Node 22.18 / 24.2 onwards.
# On older Node the CLI exits 0 with *no output at all*, which is maddening to
# debug — so we check explicitly instead of letting it fail silently later.

NODE_BIN_DIR=""
if [ -n "$NODE_DIR" ]; then
  NODE_BIN_DIR="$NODE_DIR"
  log "using provided node dir: $NODE_BIN_DIR"
elif command -v node >/dev/null 2>&1; then
  cur_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$cur_major" -ge 24 ]; then
    NODE_BIN_DIR=$(dirname "$(command -v node)")
    log "system node $(node -v) is new enough"
  else
    log "system node $(node -v) is too old (need >= 24)"
  fi
fi

if [ -z "$NODE_BIN_DIR" ]; then
  [ "$INSTALL_NODE" = "1" ] || die "node >= 24 required but not installed; rerun without --no-install-node"
  case "$(uname -m)" in
    x86_64|amd64)  narch=x64 ;;
    aarch64|arm64) narch=arm64 ;;
    *) die "unsupported CPU arch: $(uname -m)" ;;
  esac
  url="$NODE_MIRROR/v$NODE_VERSION/node-v$NODE_VERSION-linux-$narch.tar.xz"
  log "downloading node $NODE_VERSION ($narch)"
  mkdir -p "$PREFIX/node"
  tmp="$PREFIX/.node.tar.xz"
  curl -fsSL "$url" -o "$tmp" || die "failed to download $url"
  tar -xJf "$tmp" -C "$PREFIX/node" --strip-components=1 || die "failed to extract node"
  rm -f "$tmp"
  NODE_BIN_DIR="$PREFIX/node/bin"
fi

export PATH="$NODE_BIN_DIR:$PATH"
node -v
npm -v >/dev/null 2>&1 || die "npm not found next to node ($NODE_BIN_DIR)"

# ---------------------------------------------------------------- dsh package

DSH_PREFIX="$PREFIX/dsh"
DSH_BIN="$DSH_PREFIX/bin/dsh"

if [ -x "$DSH_BIN" ]; then
  have=$("$DSH_BIN" -V 2>/dev/null || true)
  if [ "$have" = "$DSH_VERSION" ]; then
    log "dsh $have already installed"
  else
    log "reinstalling dsh ($have -> $DSH_VERSION)"
    "$DSH_BIN" >/dev/null 2>&1 || true
  fi
fi

if [ ! -x "$DSH_BIN" ] || [ "$("$DSH_BIN" -V 2>/dev/null || true)" != "$DSH_VERSION" ]; then
  log "installing @deepseek-ai/dsh@$DSH_VERSION (this can take a few minutes)"
  export npm_config_cache="$PREFIX/.npm-cache"
  npm install -g --prefix "$DSH_PREFIX" --cache "$npm_config_cache" \
      --no-fund --no-audit --loglevel=error \
      "@deepseek-ai/dsh@$DSH_VERSION" || die "npm install failed"
fi

[ -x "$DSH_BIN" ] || die "dsh binary not found at $DSH_BIN"
ver=$("$DSH_BIN" -V 2>/dev/null || true)
[ -n "$ver" ] || die "dsh printed no version — node too old? (node $(node -v))"
log "dsh version: $ver"

# ---------------------------------------------------------------- env + runner

DSH_HOME_DEFAULT="$PREFIX/dsh-home"
cat > "$PREFIX/dsh-remote.env" <<EOF
# Generated by install-remote.sh — safe to edit.
DSH_NODE_BIN="$NODE_BIN_DIR"
DSH_BIN="$DSH_BIN"
DSH_HOME="$DSH_HOME_DEFAULT"
DSH_WORKSPACE="$WORKSPACE"
DSH_WEB_PORT="$WEB_PORT"
EOF

# start-web.sh is embedded so `curl | bash` installs stay single-file.
cat > "$PREFIX/start-web.sh" <<'RUNNER'
#!/usr/bin/env bash
# Start (or reuse) `dsh web` on this host and print a tokenized URL.
#
#   start-web.sh            # uses DSH_WEB_PORT from dsh-remote.env (default 8787)
#   start-web.sh 9000       # explicit port
#   start-web.sh --foreground 9000   # internal: run in the foreground
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
RUNNER

chmod +x "$PREFIX/start-web.sh"

# ---------------------------------------------------------------- workspace
#
# The workspace picker in the web UI starts at the server's $HOME and has no
# "type a path" box, which makes deep paths (mounted volumes, /data/...) slow
# to reach by clicking. Pre-registering the record avoids that entirely.

if [ "$REGISTER_WS" = "1" ]; then
  WSFILE="$DSH_HOME_DEFAULT/storages/workspace.json"
  if [ -f "$WSFILE" ] && grep -q '"workspaces"[[:space:]]*:[[:space:]]*{[^}]' "$WSFILE" 2>/dev/null; then
    log "workspace record already exists, leaving it alone"
  elif command -v python3 >/dev/null 2>&1; then
    log "pre-registering workspace: $WORKSPACE"
    mkdir -p "$(dirname "$WSFILE")"
    python3 - "$WSFILE" "$WORKSPACE" <<'PY'
import json, os, sys, uuid, datetime
path, workspace = sys.argv[1], sys.argv[2]
wid = str(uuid.uuid4())
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
data = {
    "unit": {"name": "workspace", "version": 2},
    "global": {
        "initialized": True,
        "defaultWorkspaceId": wid,
        "workspaceIds": [wid],
        "archivedSessionIds": [],
        "pinnedSessionIds": [],
    },
    "tables": {"workspaces": {wid: {
        "path": workspace,
        "title": os.path.basename(workspace.rstrip("/")) or workspace,
        "sessionIds": [],
        "createdAt": now,
        "updatedAt": now,
    }}},
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
print("    wrote", path)
PY
  else
    echo "warning: python3 not found, skipping workspace pre-registration" >&2
    echo "warning: add the workspace from the web UI instead" >&2
  fi
fi

# ---------------------------------------------------------------- start + verify

log "starting dsh web on port $WEB_PORT"
URL=$(bash "$PREFIX/start-web.sh" "$WEB_PORT")

cat <<EOF

installed.
  prefix    : $PREFIX
  workspace : $WORKSPACE
  url       : $URL

From your own computer, forward the port and open that URL:

  ssh -N -L $WEB_PORT:127.0.0.1:$WEB_PORT <your-host>
  open "$URL"

Or just run the connect script from this repo (it does both).
EOF
REMOTE
)

info "installing on $TARGET (prefix: $PREFIX)"
URL_OUT=$(remote_script "$REMOTE_BODY" \
  "$PREFIX" "$WORKSPACE" "$WEB_PORT" "$DSH_VERSION" \
  "$NODE_VERSION" "$NODE_MIRROR" "$NODE_DIR" "$INSTALL_NODE" "$REGISTER_WS")

printf '%s\n' "$URL_OUT"

URL=$(printf '%s\n' "$URL_OUT" | grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[A-Za-z0-9_-]*' | tail -1 || true)
if [ -z "$URL" ]; then
  die "install finished but no tokenized URL was found in the output"
fi

SSH_HINT="$TARGET"
if [ -n "$SSH_PORT" ]; then SSH_HINT="-p $SSH_PORT $TARGET"; fi

cat <<EOF

$(printf '\033[32mdone.\033[0m')

  Workspace lives on $TARGET — the agent, the files and the whole
  conversation history stay there, so any computer sees the same thing.

  Open it from this machine:

    ssh -N -L $WEB_PORT:127.0.0.1:$WEB_PORT $SSH_HINT &
    open "$URL"          # macOS
    xdg-open "$URL"      # Linux
    start "" "$URL"      # Windows (cmd)

  Or use the helper in this repo:

    ./connect/connect.sh --host $HOST --remote-script $PREFIX/start-web.sh

  Keep the remote install root private: it holds your session history.
EOF
