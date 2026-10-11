#!/usr/bin/env bash
# stop.sh — stop the DeepSeek-V4.1-Flash TP2 engine on both nodes. Run ON THE HEAD (120).
#
#   ./stop.sh        stop the engines (frees the GPU); the container stays up (reused, never removed)
#   ./stop.sh all    also stop the container (docker stop; it is NOT removed)
#
# Config comes from .env (optional) with the defaults below as fallback.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SRC/.env" ]; then set -a; . "$SRC/.env"; set +a; fi

SSH_USER="${SSH_USER:-dgxspark}"
HEAD_IP="${HEAD_IP:-192.168.1.100}"
WORKER_IP="${WORKER_IP:-192.168.1.101}"
CONTAINER="${CONTAINER:-tf-dsv41}"
SSH="ssh -o ConnectTimeout=5"

# this script is meant to run on the head
case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }

echo "[stop] rank0 (head)";   docker exec "$CONTAINER" pkill -9 -f tensorfold-native 2>/dev/null; true
echo "[stop] rank1 (worker)"; on_worker "docker exec '$CONTAINER' pkill -9 -f tf-dsv41-lanes 2>/dev/null; true"
sleep 2
docker exec "$CONTAINER" pgrep -af tensorfold-native || echo "rank0: clean"
on_worker "docker exec '$CONTAINER' pgrep -af tf-dsv41-lanes || echo 'rank1: clean'"

if [ "${1:-}" = "all" ]; then
  echo "[containers]"
  "$SRC/tf.sh" stop
fi
