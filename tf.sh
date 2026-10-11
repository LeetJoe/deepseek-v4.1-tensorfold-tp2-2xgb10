#!/usr/bin/env bash
# tf.sh — manage the serving container on BOTH nodes. Run ON THE HEAD.
#
# Reuse-first: the existing container is started/stopped/restarted as-is and is NEVER removed.
# (The image is only used by `create`, for when the container is missing.)
#
#   tf.sh start | up   create it if missing, then start it on both nodes
#   tf.sh stop         stop it on both nodes
#   tf.sh restart      restart it on both nodes
#   tf.sh status       show state
#   tf.sh logs         last 20 lines of the container's own stdout
#   tf.sh create       (rare) create it from the image via docker-compose
#
# Config comes from .env (optional) with the defaults below as fallback.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SRC/.env" ]; then set -a; . "$SRC/.env"; set +a; fi

SSH_USER="${SSH_USER:-dgxspark}"
HEAD_IP="${HEAD_IP:-192.168.1.100}"
WORKER_IP="${WORKER_IP:-192.168.1.101}"
HEAD_MODELS_DIR="${HEAD_MODELS_DIR:-/home/dgxspark/models}"
HEAD_CACHE_DIR="${HEAD_CACHE_DIR:-/home/dgxspark/cache}"
# worker dirs default to the head's unless explicitly overridden
WORKER_MODELS_DIR="${WORKER_MODELS_DIR:-$HEAD_MODELS_DIR}"
WORKER_CACHE_DIR="${WORKER_CACHE_DIR:-$HEAD_CACHE_DIR}"
WORKER_NODEDIR="${WORKER_NODEDIR:-$SRC}"
CONTAINER="${CONTAINER:-tf-dsv41}"
SSH="ssh -o ConnectTimeout=5"

# this script is meant to run on the head
case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }

# create the container from the image via compose (head from this repo dir, worker from a copy)
ensure() {
  echo "[head]";   (cd "$SRC" && docker compose up -d)
  on_worker "mkdir -p '$WORKER_NODEDIR'"
  scp -q "$SRC/docker-compose.yml" "$SSH_USER@$WORKER_IP:$WORKER_NODEDIR/docker-compose.yml"
  [ -f "$SRC/.env" ] && scp -q "$SRC/.env" "$SSH_USER@$WORKER_IP:$WORKER_NODEDIR/.env"
  echo "[worker]"; on_worker "cd '$WORKER_NODEDIR' && HEAD_MODELS_DIR='$WORKER_MODELS_DIR' \
                     HEAD_CACHE_DIR='$WORKER_CACHE_DIR' docker compose up -d"
}

cmd=${1:-status}
case "$cmd" in
  start|up)
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
      echo "[containers] $CONTAINER missing — creating it"
      ensure
    fi
    echo "[head]";   docker start "$CONTAINER" >/dev/null 2>&1
    docker inspect -f "$CONTAINER: {{.State.Status}}" "$CONTAINER"
    echo "[worker]"; on_worker "docker start '$CONTAINER' >/dev/null 2>&1; docker inspect -f '$CONTAINER: {{.State.Status}}' '$CONTAINER'"
    ;;
  stop)
    echo "[head]";   docker stop "$CONTAINER" >/dev/null 2>&1; echo "$CONTAINER: stopped"
    echo "[worker]"; on_worker "docker stop '$CONTAINER' >/dev/null 2>&1; echo '$CONTAINER: stopped'"
    ;;
  restart)
    echo "[head]";   docker restart "$CONTAINER" >/dev/null
    docker inspect -f "$CONTAINER: {{.State.Status}}" "$CONTAINER"
    echo "[worker]"; on_worker "docker restart '$CONTAINER' >/dev/null; docker inspect -f '$CONTAINER: {{.State.Status}}' '$CONTAINER'"
    ;;
  status|ps)
    echo "[head]";   docker ps -a --filter "name=^${CONTAINER}$" --format "$CONTAINER: {{.Status}}"
    echo "[worker]"; on_worker "docker ps -a --filter 'name=^${CONTAINER}\$' --format '$CONTAINER: {{.Status}}'"
    ;;
  logs)
    echo "[head]";   docker logs --tail 20 "$CONTAINER" 2>&1
    echo "[worker]"; on_worker "docker logs --tail 20 '$CONTAINER' 2>&1"
    ;;
  create) ensure ;;
  *) echo "usage: tf.sh {start|stop|restart|status|logs|create}"; exit 2 ;;
esac
