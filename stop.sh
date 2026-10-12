#!/usr/bin/env bash
# stop.sh — stop the DeepSeek-V4.1-Flash TP2 engine on both nodes. Run ON THE HEAD.
#
#   ./stop.sh        stop the engines AND the containers (docker stop; they are NOT removed)
#   ./stop.sh keep   stop the engines only and keep the containers running
#   ./stop.sh all    same as ./stop.sh (kept for compatibility)
#
# Stopping the container releases its RAM/shm and the last GPU context; `docker start`
# (tf.sh start / start.sh) brings the very same container back. Because the container is
# stopped explicitly, compose's `restart: unless-stopped` will not auto-start it again.
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
case "${1:-all}" in
  keep)                STOP_CONTAINER=0 ;;
  ""|all|stop)         STOP_CONTAINER=1 ;;   # "" = ./stop.sh, "stop" = ./start.sh stop
  -h|--help)           echo "usage: stop.sh [all|stop|keep]   (default: all)   keep = engines only"; exit 0 ;;
  *) echo "usage: stop.sh [all|stop|keep]" >&2; exit 2 ;;
esac

# this script is meant to run on the head
case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }

# 0 = the container runs here, 1 = it is not running (missing or stopped), 2 = cannot tell (ssh failed)
container_running() { # $1=local|worker
  local rc out
  if [ "$1" = local ]; then
    out=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null); rc=$?
  else
    out=$(on_worker "docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null"); rc=$?
  fi
  [ $rc -ne 0 ] && return 2
  [ "$out" = "true" ]
}

# stop the engine process on one node (only if its container runs); container is left as it is
kill_engine() { # $1=rank label, $2=local|worker, $3=process pattern
  echo "[stop] $1"
  if ! container_running "$2"; then
    echo "       container $CONTAINER not running — nothing to kill"
    return 0
  fi
  case "$2" in
    local)  docker exec "$CONTAINER" pkill -9 -f "$3" 2>/dev/null ;;
    worker) on_worker "docker exec '$CONTAINER' pkill -9 -f '$3' 2>/dev/null" ;;
  esac
  # pkill exits 1 when nothing matched, i.e. the engine was already down — that is fine here.
  return 0
}

kill_engine "rank0 (head)"   local  tensorfold-native
kill_engine "rank1 (worker)" worker tf-dsv41-lanes
sleep 5

echo "[check]"
docker exec "$CONTAINER" pgrep -af tensorfold-native 2>/dev/null || echo "rank0: clean"
on_worker "docker exec '$CONTAINER' pgrep -af tf-dsv41-lanes 2>/dev/null || echo 'rank1: clean'"

if [ "$STOP_CONTAINER" = 1 ]; then
  # stop the containers too: this frees their RAM/shm and drops the last GPU context.
  # tf.sh stop reports the per-node state and is safe to re-run when already stopped.
  echo "[containers] stop (containers are kept, not removed)"
  "$SRC/tf.sh" stop
else
  echo "[keep] containers left running (./stop.sh keep)"
fi
