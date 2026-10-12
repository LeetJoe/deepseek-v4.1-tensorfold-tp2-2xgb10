#!/usr/bin/env bash
# tf.sh — manage the serving container on BOTH nodes. Run ON THE HEAD.
#
# Reuse-first: the existing container is started/stopped/restarted as-is and is NEVER removed.
# (The image is only used by `create`, for when the container is missing.)
# Every command is idempotent, so a state change can be repeated safely. `stop` stops the
# container explicitly; compose's `restart: unless-stopped` will therefore not auto-start it.
#
#   tf.sh start | up   create it if missing, then start it on both nodes
#   tf.sh stop         stop it on both nodes (no-op if already stopped)
#   tf.sh restart      restart it on both nodes
#   tf.sh status       show container state (and whether the engine runs inside it)
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

# usage works anywhere (and before the head check)
case "${1:-status}" in
  -h|--help) echo "usage: tf.sh {start|stop|restart|status|logs|create}"; exit 0 ;;
esac

# this script is meant to run on the head
case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }

# 0 = running, 1 = stopped or missing, 2 = cannot tell (ssh failed)
is_running() { # $1=local|worker
  local out rc
  if [ "$1" = local ]; then
    out=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null); rc=$?
  else
    out=$(on_worker "docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null"); rc=$?
  fi
  [ $rc -ne 0 ] && return 2
  [ "$out" = "true" ]
}

# does the container exist (running or stopped)?  2 = cannot tell (ssh failed)
container_exists() { # $1=local|worker
  if [ "$1" = local ]; then docker inspect "$CONTAINER" >/dev/null 2>&1
  else on_worker "docker inspect '$CONTAINER' >/dev/null 2>&1"; fi
}

# one line per node: container state + whether the engine process runs inside it
show_state() { # $1=rank label, $2=local|worker, $3=engine process pattern
  if ! is_running "$2"; then
    if container_exists "$2"; then echo "$1: $CONTAINER stopped"
    else                          echo "$1: $CONTAINER missing (run: tf.sh create)"; fi
    return 0
  fi
  local engine
  if [ "$2" = local ]; then
    docker exec "$CONTAINER" pgrep -f "$3" >/dev/null 2>&1 && engine=yes || engine=no
  else
    on_worker "docker exec '$CONTAINER' pgrep -f '$3' >/dev/null 2>&1" && engine=yes || engine=no
  fi
  echo "$1: $CONTAINER running, engine=$engine"
}

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
    echo "[head]";   docker start "$CONTAINER" >/dev/null 2>&1; show_state "head" local tensorfold-native
    echo "[worker]"; on_worker "docker start '$CONTAINER' >/dev/null 2>&1"; show_state "worker" worker tf-dsv41-lanes
    ;;
  stop)
    echo "[head]"
    if is_running local; then docker stop "$CONTAINER" >/dev/null 2>&1; echo "$CONTAINER: stopped"
    else                           echo "$CONTAINER: already stopped"; fi
    echo "[worker]"
    on_worker "if [ \"\$(docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null)\" = true ]; then
                 docker stop '$CONTAINER' >/dev/null 2>&1; echo '$CONTAINER: stopped'
               else echo '$CONTAINER: already stopped'; fi"
    ;;
  restart)
    # running -> restart; stopped -> start (docker restart refuses a stopped container);
    # missing -> create it first, like `start` does
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
      echo "[containers] $CONTAINER missing — creating it"
      ensure
    fi
    echo "[head]"
    if is_running local; then docker restart "$CONTAINER" >/dev/null 2>&1; echo "[restart]"
    else                     docker start   "$CONTAINER" >/dev/null 2>&1; echo "[start] (was stopped)"; fi
    show_state "head" local tensorfold-native
    echo "[worker]"
    on_worker "if [ \"\$(docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null)\" = true ]; then
                 docker restart '$CONTAINER' >/dev/null 2>&1; echo '[restart]'
               else docker start '$CONTAINER' >/dev/null 2>&1; echo '[start] (was stopped)'; fi"
    show_state "worker" worker tf-dsv41-lanes
    ;;
  status|ps)
    show_state "head"   local  tensorfold-native
    show_state "worker" worker tf-dsv41-lanes
    ;;
  logs)
    echo "[head]";   docker logs --tail 20 "$CONTAINER" 2>&1
    echo "[worker]"; on_worker "docker logs --tail 20 '$CONTAINER' 2>&1"
    ;;
  create) ensure ;;
  *) echo "usage: tf.sh {start|stop|restart|status|logs|create}"; exit 2 ;;
esac
