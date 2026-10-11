#!/usr/bin/env bash
# start.sh — start the DeepSeek-V4.1-Flash TP2 service on both nodes. Run ON THE HEAD.
#
#   ./start.sh            start  (idempotent: stops any running engine, reuses/creates the container,
#                                 starts rank 1 then rank 0, waits until ready, smoke-tests)
#   ./start.sh restart    same as start
#   ./start.sh stop       stop the engines (same as stop.sh)
#
# The container is REUSED (never deleted); tf.sh handles it.
# Config comes from .env (optional) with the defaults below as fallback.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SRC/.env" ]; then set -a; . "$SRC/.env"; set +a; fi

SSH_USER="${SSH_USER:-dgxspark}"
HEAD_IP="${HEAD_IP:-192.168.1.100}"
WORKER_IP="${WORKER_IP:-192.168.1.101}"
HEAD_CX_IP="${HEAD_CX_IP:-10.8.8.1}"
WORKER_CX_IP="${WORKER_CX_IP:-10.8.8.2}"
HEAD_CACHE_DIR="${HEAD_CACHE_DIR:-/home/dgxspark/cache}"
# worker cache dir defaults to the head's unless explicitly overridden
WORKER_CACHE_DIR="${WORKER_CACHE_DIR:-$HEAD_CACHE_DIR}"
CONTAINER="${CONTAINER:-tf-dsv41}"
SSH="ssh -o ConnectTimeout=5"

LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8888}"
TP_MASTER_IP="$HEAD_CX_IP"
TP_MASTER_PORT="${TP_MASTER_PORT:-29620}"
TP_WORLD="${TP_WORLD:-2}"

MODELS_MOUNT="${MODELS_MOUNT:-/workspace/models}"
CACHE_MOUNT="${CACHE_MOUNT:-/workspace/cache}"

NCCL_IB_HCA="${NCCL_IB_HCA:-roceP2p1s0f1,rocep1s0f1}"
NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX:-5}"
NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enP2p1s0f1np1}"
NCCL_NET_PLUGIN="${NCCL_NET_PLUGIN:-spcx}"
NCCL_ENV="NCCL_IB_HCA=$NCCL_IB_HCA NCCL_IB_GID_INDEX=$NCCL_IB_GID_INDEX NCCL_SOCKET_IFNAME=$NCCL_SOCKET_IFNAME NCCL_NET_PLUGIN=$NCCL_NET_PLUGIN"

WEIGHTS_SUBDIR="${WEIGHTS_SUBDIR:-DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw}"
ENGRAM_SUBDIR="${ENGRAM_SUBDIR:-DeepSeek-V4.1-Flash}"
MODEL_NAME="${MODEL_NAME:-DeepSeek-V4.1-Flash-TF}"
CONTEXT="${CONTEXT:-1048576}"
PARALLEL="${PARALLEL:-4}"
MAX_TOKENS="${MAX_TOKENS:-32768}"
TEMPERATURE="${TEMPERATURE:-1.0}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"
BACKEND="${BACKEND:-cuda}"
POOL="${POOL:-1048576}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-360}"
READY_INTERVAL_S="${READY_INTERVAL_S:-5}"
SMOKE_TIMEOUT_S="${SMOKE_TIMEOUT_S:-120}"

# this script is meant to run on the head
case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }

RANK1_CMD="docker exec -d $CONTAINER bash -c \"
TF_DS_REPLAY_FLOOR=1 \\
$NCCL_ENV \\
$CACHE_MOUNT/tf-build/bin/tf-dsv41-lanes \\
  $MODELS_MOUNT/$WEIGHTS_SUBDIR \\
  $CACHE_MOUNT/dsv41/tf-ds-rank 1 $TP_WORLD $TP_MASTER_IP $TP_MASTER_PORT $CACHE_MOUNT/kit \\
  --engram $MODELS_MOUNT/$ENGRAM_SUBDIR \\
  --token-map $CACHE_MOUNT/dsv41_token_map.json \\
  --pool $POOL --graphs 1 --side 1 --prefetch 1 --aio 1 \\
  > $CACHE_MOUNT/temp/lanes.log 2>&1\""

RANK0_CMD="docker exec -d $CONTAINER bash -c \"
TF_DS_REPLAY_FLOOR=1 TF_TP_WORLD=$TP_WORLD TF_TP_MASTER=$TP_MASTER_IP TF_TP_PORT=$TP_MASTER_PORT \\
TF_DS_RANK_CACHE=$CACHE_MOUNT/dsv41/tf-ds-rank \\
TF_DS_KIT=$CACHE_MOUNT/kit TENSORFOLD_CUDA_KERNELS=$CACHE_MOUNT/kit/aot \\
TF_DS_ENGRAM=$MODELS_MOUNT/$ENGRAM_SUBDIR \\
TF_DS_TOKEN_MAP=$CACHE_MOUNT/dsv41_token_map.json \\
TF_DS_GRAPHS=1 TF_DS_HC_SIDE=1 TF_DS_L2_PREFETCH=1 TF_DS_ENGRAM_AIO=1 \\
$NCCL_ENV \\
$CACHE_MOUNT/tf-build/native/bin/tensorfold-native serve \\
  $MODELS_MOUNT/$WEIGHTS_SUBDIR \\
  --host $LISTEN_HOST --port $LISTEN_PORT --name $MODEL_NAME \\
  --context $CONTEXT --parallel $PARALLEL --thinking --max-tokens $MAX_TOKENS \\
  --temperature $TEMPERATURE --top-p $TOP_P --top-k $TOP_K --backend $BACKEND \\
  > $CACHE_MOUNT/temp/serve.log 2>&1\""

stop_engines() {
  echo "[stop] rank0 (head)";   docker exec "$CONTAINER" pkill -9 -f tensorfold-native 2>/dev/null; true
  echo "[stop] rank1 (worker)"; on_worker "docker exec '$CONTAINER' pkill -9 -f tf-dsv41-lanes 2>/dev/null; true"
  sleep 3
}

wait_ready() {
  echo "[wait] /v1/models (up to ${READY_TIMEOUT_S}s) ..."
  local i code
  for i in $(seq 1 $((READY_TIMEOUT_S / READY_INTERVAL_S))); do
    code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w "%{http_code}" \
             "http://127.0.0.1:$LISTEN_PORT/v1/models" 2>/dev/null)
    [ "$code" = "200" ] && { echo "[ready] after ~$((i*READY_INTERVAL_S))s"; return 0; }
    docker exec "$CONTAINER" pgrep -f tensorfold-native >/dev/null 2>&1 \
      || { echo "[error] rank0 died; check $CACHE_MOUNT/temp/serve.log and lanes.log"; return 1; }
    sleep "$READY_INTERVAL_S"
  done
  echo "[error] not ready within ${READY_TIMEOUT_S}s"; return 1
}

case "${1:-start}" in
  stop) stop_engines ;;
  start|restart|"")
    stop_engines
    echo "[containers] reusing/creating $CONTAINER"
    "$SRC/tf.sh" start
    mkdir -p "$HEAD_CACHE_DIR/temp"
    on_worker "mkdir -p '$WORKER_CACHE_DIR/temp'"
    echo "[start] rank1 (worker)"; on_worker "$RANK1_CMD"
    sleep 15
    echo "[start] rank0 (head)";   bash -c "$RANK0_CMD"
    if wait_ready; then
      echo "[smoke]"
      docker exec "$CONTAINER" curl -s -m "$SMOKE_TIMEOUT_S" \
        "http://127.0.0.1:$LISTEN_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_tokens\":8,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false}}" \
        | head -c 160
      echo
    fi
    ;;
  *) echo "usage: start.sh [start|restart|stop]"; exit 2 ;;
esac
