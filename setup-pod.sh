#!/usr/bin/env bash
# setup-pod.sh - provision a RunPod pod with tmux, Claude Code, Codex, node and uv,
# with all tool state on /workspace so it survives pod stop/start.
#
# Usage:
#   ./setup-pod.sh <user@ssh.runpod.io> [--update] [--sync-auth]
#   ./setup-pod.sh <root@ip> -p <port>   direct TCP connection, used as-is
#   ./setup-pod.sh                       reuses the last pod (stored in .last-pod)
#
# You can paste the full ssh command RunPod shows, the leading "ssh" and any
# "-i <key>" are understood:
#   ./setup-pod.sh ssh abc123-xyz@ssh.runpod.io -i ~/.ssh/runpod/id_ed25519
#
# How it connects: RunPod's ssh.runpod.io proxy only supports interactive
# shells (no command execution, no scp), so when given a proxy address this
# script uses one scripted interactive session to (a) make sure your public
# key is in the pod's ~/.ssh/authorized_keys and (b) discover the pod's direct
# ip/port from $RUNPOD_PUBLIC_IP / $RUNPOD_TCP_PORT_22. All real work then
# happens over the direct connection.
#
# Flags:
#   --update     update Claude Code, Codex and uv on the pod to latest versions
#   --sync-auth  re-push local auth/config files even if the pod already has them
#                (default: only files the pod is missing are pushed)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_KEY=$HOME/.ssh/runpod/id_ed25519
LAST_POD_FILE=$SCRIPT_DIR/.last-pod

# ---------- parse arguments ----------
UPDATE=0
SYNC_AUTH=0
TARGET=""
KEY=""
EXTRA=()
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a=${args[$i]}
  if [ $i = 0 ] && [ "$a" = ssh ]; then i=$((i+1)); continue; fi
  case $a in
    --update)    UPDATE=1 ;;
    --sync-auth) SYNC_AUTH=1 ;;
    -i)          i=$((i+1)); KEY=${args[$i]} ;;
    *@*)         TARGET=$a ;;
    *)           EXTRA+=("$a") ;;
  esac
  i=$((i+1))
done

# ---------- last-pod cache ----------
LAST_TARGET="" LAST_KEY="" LAST_DIRECT_HOST="" LAST_DIRECT_PORT=""
if [ -f "$LAST_POD_FILE" ] && grep -q '^LAST_TARGET=' "$LAST_POD_FILE"; then
  . "$LAST_POD_FILE"
fi

if [ -z "$TARGET" ]; then
  if [ -n "$LAST_TARGET" ]; then
    TARGET=$LAST_TARGET
    KEY=${KEY:-$LAST_KEY}
    echo "Using last pod: $TARGET"
  else
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
  fi
elif [ "$TARGET" != "$LAST_TARGET" ]; then
  # new pod, forget the cached direct connection
  LAST_DIRECT_HOST="" LAST_DIRECT_PORT=""
fi
KEY=${KEY:-$DEFAULT_KEY}
[ -f "$KEY" ] || { echo "ERROR: ssh key not found: $KEY" >&2; exit 1; }

SSH_BASE=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
              -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY")

# ---------- resolve a direct (exec-capable) connection ----------
DIRECT_HOST="" DIRECT_PORT=""

try_direct() { # <user@host> <port> -> 0 if exec works
  "${SSH_BASE[@]}" -o ConnectTimeout=10 -p "$2" "$1" 'echo DIRECT_OK' 2>/dev/null \
    | grep -q DIRECT_OK
}

proxy_exec() { # run a command line in a scripted interactive proxy session, print transcript
  { printf 'stty -echo\n'; sleep 2; printf '%s\n' "$1"; sleep 1; printf 'exit\n'; } \
    | ssh -tt -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
          -o IdentitiesOnly=yes -i "$KEY" ${EXTRA[@]+"${EXTRA[@]}"} "$TARGET" 2>/dev/null \
    | tr -d '\r'
}

case $TARGET in
  *ssh.runpod.io*)
    if [ -n "$LAST_DIRECT_HOST" ] && try_direct "$LAST_DIRECT_HOST" "$LAST_DIRECT_PORT"; then
      DIRECT_HOST=$LAST_DIRECT_HOST
      DIRECT_PORT=$LAST_DIRECT_PORT
      echo "==> Using cached direct connection: $DIRECT_HOST -p $DIRECT_PORT"
    else
      echo "==> Probing pod via proxy (ensuring ssh key + discovering direct ip/port)"
      pub=$(ssh-keygen -y -f "$KEY")
      cmd="grep -qF \"$pub\" ~/.ssh/authorized_keys 2>/dev/null || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \"$pub\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys; }; echo \"PROBE ip=[\$RUNPOD_PUBLIC_IP] port=[\$RUNPOD_TCP_PORT_22]\""
      probe=$(proxy_exec "$cmd" | grep -ao 'PROBE ip=\[.*' | grep -v 'RUNPOD_PUBLIC_IP' | tail -1 || true)
      ip=$(printf '%s' "$probe" | sed -n 's/.*ip=\[\([^]]*\)\].*/\1/p')
      port=$(printf '%s' "$probe" | sed -n 's/.*port=\[\([^]]*\)\].*/\1/p')
      if [ -z "$ip" ] || [ -z "$port" ]; then
        echo "ERROR: could not reach the pod via the proxy, or it has no direct TCP SSH." >&2
        echo "This tool needs 'SSH over exposed TCP' (port 22 in the pod's template)." >&2
        exit 1
      fi
      DIRECT_HOST=root@$ip
      DIRECT_PORT=$port
      echo "    direct connection: $DIRECT_HOST -p $DIRECT_PORT"
      try_direct "$DIRECT_HOST" "$DIRECT_PORT" || {
        echo "ERROR: direct ssh to $DIRECT_HOST -p $DIRECT_PORT failed even after key setup." >&2
        exit 1
      }
    fi
    ;;
  *)
    # already a direct address; port from -p in extra args, default 22
    DIRECT_HOST=$TARGET
    DIRECT_PORT=22
    j=0
    while [ $j -lt ${#EXTRA[@]:-0} ]; do
      if [ "${EXTRA[$j]}" = -p ]; then j=$((j+1)); DIRECT_PORT=${EXTRA[$j]}; fi
      j=$((j+1))
    done
    try_direct "$DIRECT_HOST" "$DIRECT_PORT" || {
      echo "ERROR: cannot run commands over ssh on $DIRECT_HOST -p $DIRECT_PORT" >&2
      exit 1
    }
    ;;
esac

run() { "${SSH_BASE[@]}" -p "$DIRECT_PORT" "$DIRECT_HOST" "$@"; }

echo "==> Checking /workspace"
run 'test -d /workspace && echo "    connected: $(hostname), /workspace present"' || {
  echo "ERROR: /workspace is missing on the pod." >&2
  exit 1
}

cat > "$LAST_POD_FILE" <<EOF
LAST_TARGET='$TARGET'
LAST_KEY='$KEY'
LAST_DIRECT_HOST='$DIRECT_HOST'
LAST_DIRECT_PORT='$DIRECT_PORT'
EOF

echo "==> Uploading bootstrap script"
run 'cat > /workspace/bootstrap.sh && chmod +x /workspace/bootstrap.sh' < "$SCRIPT_DIR/bootstrap.sh"

echo "==> Running bootstrap (first run takes a few minutes, later runs are fast)"
if [ "$UPDATE" = 1 ]; then
  run '/workspace/bootstrap.sh --update'
else
  run '/workspace/bootstrap.sh'
fi

echo "==> Syncing auth and config to the pod"
remote_state=$(run 'for f in home/.codex/auth.json home/.codex/config.toml home/.claude/.credentials.json home/.claude/CLAUDE.md home/.gitconfig; do
  if [ -f "/workspace/$f" ]; then echo 1; else echo 0; fi
done')
{
  read -r has_codex_auth
  read -r has_codex_cfg
  read -r has_claude_cred
  read -r has_claude_md
  read -r has_gitcfg
} <<< "$remote_state"

sync_file() { # <local path> <remote path> <mode> <already-on-pod flag> <label>
  if [ ! -f "$1" ]; then
    echo "    $5: no local file, skipping"
    return
  fi
  if [ "$4" = 1 ] && [ "$SYNC_AUTH" = 0 ]; then
    echo "    $5: already on pod"
    return
  fi
  echo "    $5: pushing"
  run "cat > '$2' && chmod $3 '$2'" < "$1"
}

sync_file "$HOME/.codex/auth.json"   /workspace/home/.codex/auth.json   600 "$has_codex_auth" "Codex auth"
sync_file "$HOME/.codex/config.toml" /workspace/home/.codex/config.toml 644 "$has_codex_cfg"  "Codex config"
sync_file "$HOME/.claude/CLAUDE.md"  /workspace/home/.claude/CLAUDE.md  644 "$has_claude_md"  "global CLAUDE.md"
sync_file "$HOME/.gitconfig"         /workspace/home/.gitconfig         644 "$has_gitcfg"     "gitconfig"

# Claude Code credentials live in the macOS Keychain, not in a file
if [ "$has_claude_cred" = 0 ] || [ "$SYNC_AUTH" = 1 ]; then
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  if [ -n "$creds" ]; then
    echo "    Claude auth: pushing from Keychain"
    printf '%s' "$creds" | run 'cat > /workspace/home/.claude/.credentials.json && chmod 600 /workspace/home/.claude/.credentials.json'
  else
    echo "    Claude auth: not found in Keychain. Run 'claude' on the pod and /login once; it persists."
  fi
else
  echo "    Claude auth: already on pod"
fi

echo "==> Verifying tools in a fresh login shell"
run 'bash -lc "echo \"    node   $(node -v 2>/dev/null || echo MISSING)\";
               echo \"    tmux   $(tmux -V 2>/dev/null || echo MISSING)\";
               echo \"    claude $(claude --version 2>/dev/null || echo MISSING)\";
               echo \"    codex  $(codex --version 2>/dev/null || echo MISSING)\";
               echo \"    uv     $(uv --version 2>/dev/null || echo MISSING)\""'

echo "==> Done. Connect with:"
echo "    ./pod.sh    (attaches persistent tmux session 'main')"
