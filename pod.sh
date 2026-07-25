#!/usr/bin/env bash
# pod.sh - ssh into the pod and attach the persistent tmux session "main".
#
# Usage:
#   ./pod.sh              connect to the last pod set up by setup-pod.sh
#   ./pod.sh shell        plain shell instead of tmux
#
# Uses the direct ip/port cached in .last-pod by setup-pod.sh. If the pod was
# restarted (ip/port changed), re-run ./setup-pod.sh first; it refreshes the
# cache and reinstalls the wiped apt packages in one go.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LAST_POD_FILE=$SCRIPT_DIR/.last-pod

LAST_TARGET="" LAST_KEY="" LAST_DIRECT_HOST="" LAST_DIRECT_PORT=""
if [ -f "$LAST_POD_FILE" ] && grep -q '^LAST_TARGET=' "$LAST_POD_FILE"; then
  . "$LAST_POD_FILE"
fi

if [ -z "$LAST_DIRECT_HOST" ]; then
  echo "No pod on record yet. Run ./setup-pod.sh <user@host> first." >&2
  exit 1
fi

SSH=(ssh -t -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        -o IdentitiesOnly=yes -i "$LAST_KEY" -p "$LAST_DIRECT_PORT" "$LAST_DIRECT_HOST")

if [ "${1:-}" = shell ]; then
  exec "${SSH[@]}"
fi

if ! "${SSH[@]}" 'exec bash -lc "exec tmux new-session -A -s main"'; then
  echo ""
  echo "Could not attach (pod restarted? ip/port changed?)."
  echo "Re-run ./setup-pod.sh to refresh the connection and reinstall tmux."
  exit 1
fi
