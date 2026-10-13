#!/usr/bin/env bash
# prepare.sh — everything between "we have the image" and "./start.sh".
#
# Run ON THE HEAD, once. Idempotent: every step skips what already exists, so re-running is safe.
#
#   1 repos    this repo + TensorFold (engine branch, plus a tp2 worktree for the Python side)
#   2 weights  EXL3 checkpoint + the Engram shards, into $HEAD_MODELS_DIR
#   3 engine   zig build -> cache/tf-build
#   4 kit      repo kit/ -> cache/kit, the 5 generated files made, MANIFEST verified
#   5 inputs   token map, then the A-phase rank cache (both nodes, rank 0 first)
#
# Steps 3-5 run on BOTH nodes; repos and weights are rsynced to the worker. The nodes cannot reach
# github/huggingface (HTTP 000) — clone/download from a host that can and rsync, or export
# HTTP(S)_PROXY. Weights fall back to modelscope when HF is unreachable.
#
# Config comes from .env (optional) with the defaults below as fallback.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SRC/.env" ]; then cp "$SRC/.env.example" "$SRC/.env"; echo "[.env] created from .env.example"; fi
set -a; . "$SRC/.env"; set +a

SSH_USER="${SSH_USER:-dgxspark}"
HEAD_IP="${HEAD_IP:-192.168.1.100}"
WORKER_IP="${WORKER_IP:-192.168.1.101}"
HEAD_CX_IP="${HEAD_CX_IP:-10.8.8.1}"
HEAD_MODELS_DIR="${HEAD_MODELS_DIR:-/home/dgxspark/models}"
HEAD_CACHE_DIR="${HEAD_CACHE_DIR:-/home/dgxspark/cache}"
WORKER_MODELS_DIR="${WORKER_MODELS_DIR:-$HEAD_MODELS_DIR}"
WORKER_CACHE_DIR="${WORKER_CACHE_DIR:-$HEAD_CACHE_DIR}"
TENSORFOLD_DIR="${TENSORFOLD_DIR:-/home/dgxspark/code/TensorFold}"
TP2_DIR="${TP2_DIR:-/home/dgxspark/code/tensorfold-tp2}"
TENSORFOLD_REPO="${TENSORFOLD_REPO:-https://github.com/bertholomus/TensorFold.git}"
TENSORFOLD_BRANCH="${TENSORFOLD_BRANCH:-deepseek-v41-zig}"
TP2_BRANCH="${TP2_BRANCH:-deepseek-v41-tp2}"
WEIGHTS_REPO="${WEIGHTS_REPO:-Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw}"
ENGRAM_REPO="${ENGRAM_REPO:-deepseek-ai/DeepSeek-V4.1-Flash}"
ENGRAM_SHARDS="${ENGRAM_SHARDS:-47 48}"
ZIG_VERSION="${ZIG_VERSION:-0.17.0}"
ZIG_DIR="${ZIG_DIR:-/home/dgxspark/tools/zig-aarch64-linux-$ZIG_VERSION}"
CONTAINER="${CONTAINER:-tf-dsv41}"
SSH="ssh -o ConnectTimeout=5"

LISTEN_PORT="${LISTEN_PORT:-8888}"
TP_MASTER_IP="$HEAD_CX_IP"
TP_MASTER_PORT="${TP_MASTER_PORT:-29620}"
TP_WORLD="${TP_WORLD:-2}"
MODELS_MOUNT="${MODELS_MOUNT:-/workspace/models}"
CACHE_MOUNT="${CACHE_MOUNT:-/workspace/cache}"
WEIGHTS_SUBDIR="${WEIGHTS_SUBDIR:-DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw}"
ENGRAM_SUBDIR="${ENGRAM_SUBDIR:-DeepSeek-V4.1-Flash}"
NCCL_ENV="NCCL_IB_HCA=${NCCL_IB_HCA:-roceP2p1s0f1,rocep1s0f1} NCCL_IB_GID_INDEX=${NCCL_IB_GID_INDEX:-5} \
NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-enP2p1s0f1np1} NCCL_NET_PLUGIN=${NCCL_NET_PLUGIN:-spcx}"

case " $(hostname -I 2>/dev/null) " in
  *" $HEAD_IP "*) ;;
  *) echo "error: run this on the head ($HEAD_IP)" >&2; exit 1 ;;
esac

on_worker() { $SSH "$SSH_USER@$WORKER_IP" "$1"; }
say() { echo; echo "== $* =="; }

# ---------------------------------------------------------------- 0. image + container
say "0/5 image + container"
IMAGE="${IMAGE:-ghcr.io/leetjoe/deepseekv41flash_tensorfold:v1.0.0}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "[image] pulling $IMAGE"; docker pull "$IMAGE"; }
"$SRC/tf.sh" start

# ---------------------------------------------------------------- 1. repos
say "1/5 repos"
mkdir -p "$HEAD_MODELS_DIR" "$HEAD_CACHE_DIR" "$(dirname "$TENSORFOLD_DIR")"
if [ ! -d "$TENSORFOLD_DIR/.git" ]; then
  git clone --branch "$TENSORFOLD_BRANCH" "$TENSORFOLD_REPO" "$TENSORFOLD_DIR"
else
  git -C "$TENSORFOLD_DIR" fetch origin --tags && git -C "$TENSORFOLD_DIR" pull --ff-only || true
fi
if [ ! -d "$TP2_DIR" ]; then
  git -C "$TENSORFOLD_DIR" worktree add "$TP2_DIR" "origin/$TP2_BRANCH" 2>/dev/null \
    || git -C "$TENSORFOLD_DIR" worktree add "$TP2_DIR" "$TP2_BRANCH"
fi
# the container does not mount ~/code, so put both sources under the mounted cache dir too
for d in tensorfold tensorfold-tp2; do
  src="$TENSORFOLD_DIR"; [ "$d" = tensorfold-tp2 ] && src="$TP2_DIR"
  mkdir -p "$HEAD_CACHE_DIR/$d"
  rsync -a --delete "$src/" "$HEAD_CACHE_DIR/$d/"
  on_worker "mkdir -p '$WORKER_CACHE_DIR/$d'"
  rsync -a --delete "$src/" "$SSH_USER@$WORKER_IP:$WORKER_CACHE_DIR/$d/"
done
echo "[repos] $TENSORFOLD_DIR ($TENSORFOLD_BRANCH), $TP2_DIR ($TP2_BRANCH) + cache copies on both nodes"

# ---------------------------------------------------------------- 2. weights
say "2/5 weights"
for node_dir in "$HEAD_MODELS_DIR" "$WORKER_MODELS_DIR"; do
  mkdir -p "$node_dir/$WEIGHTS_SUBDIR" "$node_dir/$ENGRAM_SUBDIR"
done
if command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$WEIGHTS_REPO" --local-dir "$HEAD_MODELS_DIR/$WEIGHTS_SUBDIR" \
    || echo "[warn] EXL3 download failed — retry, or switch to modelscope"
  for s in $ENGRAM_SHARDS; do
    huggingface-cli download "$ENGRAM_REPO" "model-$s-of-*.safetensors" \
      --local-dir "$HEAD_MODELS_DIR/$ENGRAM_SUBDIR" || echo "[warn] engram shard $s failed"
  done
else
  echo "[warn] no huggingface-cli — install it, or download manually and rsync into the dirs above"
fi
echo "[weights] rsyncing models to the worker"
for sub in "$WEIGHTS_SUBDIR" "$ENGRAM_SUBDIR"; do
  rsync -a --delete "$HEAD_MODELS_DIR/$sub/" "$SSH_USER@$WORKER_IP:$WORKER_MODELS_DIR/$sub/"
done

# ---------------------------------------------------------------- 3. engine
say "3/5 engine (zig build, both nodes)"
[ -d "$ZIG_DIR" ] || { mkdir -p "$(dirname "$ZIG_DIR")"; echo "[zig] downloading $ZIG_VERSION";
  curl -fL --retry 3 --retry-all-errors -o /tmp/zig.tar.xz \
    "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-linux-$ZIG_VERSION.tar.xz" \
    && tar -xJf /tmp/zig.tar.xz -C "$(dirname "$ZIG_DIR")"; }

build_engine() { # $1 = cache dir on that node
  docker exec "$CONTAINER" bash -c "mkdir -p '$1/tf-build' && cd '$1/tensorfold' && \
    '$ZIG_DIR/zig' build install native -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe \
    -Dnvcc=/usr/local/cuda/bin/nvcc -Dsm=121 --prefix '$1/tf-build'"
}
build_engine "$CACHE_MOUNT"
on_worker "docker exec '$CONTAINER' bash -c \"mkdir -p '$CACHE_MOUNT/tf-build' && cd '$CACHE_MOUNT/tensorfold' && \
  '$ZIG_DIR/zig' build install native -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe \
  -Dnvcc=/usr/local/cuda/bin/nvcc -Dsm=121 --prefix '$CACHE_MOUNT/tf-build'\""

# ---------------------------------------------------------------- 4. kit
say "4/5 kit (both nodes)"
mkdir -p "$HEAD_CACHE_DIR/kit"
cp -an "$SRC/kit/." "$HEAD_CACHE_DIR/kit/" 2>/dev/null || true
on_worker "mkdir -p '$WORKER_CACHE_DIR/kit'"
rsync -a "$SRC/kit/" "$SSH_USER@$WORKER_IP:$WORKER_CACHE_DIR/kit/"

make_kit() { # $1 = cache dir on that node
  docker exec "$CONTAINER" bash -c "PYTHONPATH='$1/tensorfold-tp2/src' \
    python3 '$1/kit/tools/make_rope.py' '$MODELS_MOUNT/$WEIGHTS_SUBDIR' '$1/kit'"
  docker exec "$CONTAINER" bash -c "PYTHONPATH='$1/tensorfold-tp2/src' \
    python3 '$1/kit/tools/make_bias_vl.py' '$MODELS_MOUNT/$ENGRAM_SUBDIR' '$1/kit'" \
    || echo "[warn] make_bias_vl needs the ORIGINAL checkpoint's shard 3 — or take the file from the HF kit"
  docker exec "$CONTAINER" bash -c "PYTHONPATH='$1/tensorfold-tp2/src' \
    '$1/kit/tools/verify_kit.sh' --rope '$MODELS_MOUNT/$WEIGHTS_SUBDIR' '$1/tensorfold-tp2/src' \
    --bias '$MODELS_MOUNT/$ENGRAM_SUBDIR'"
}
make_kit "$CACHE_MOUNT"
on_worker "docker exec '$CONTAINER' bash -c \"PYTHONPATH='$CACHE_MOUNT/tensorfold-tp2/src' \
  python3 '$CACHE_MOUNT/kit/tools/make_rope.py' '$MODELS_MOUNT/$WEIGHTS_SUBDIR' '$CACHE_MOUNT/kit'\"; \
  docker exec '$CONTAINER' bash -c \"PYTHONPATH='$CACHE_MOUNT/tensorfold-tp2/src' \
  python3 '$CACHE_MOUNT/kit/tools/make_bias_vl.py' '$MODELS_MOUNT/$ENGRAM_SUBDIR' '$CACHE_MOUNT/kit'\"; \
  docker exec '$CONTAINER' bash -c \"PYTHONPATH='$CACHE_MOUNT/tensorfold-tp2/src' \
  '$CACHE_MOUNT/kit/tools/verify_kit.sh' --rope '$MODELS_MOUNT/$WEIGHTS_SUBDIR' '$CACHE_MOUNT/tensorfold-tp2/src' \
  --bias '$MODELS_MOUNT/$ENGRAM_SUBDIR'\""

# ---------------------------------------------------------------- 5. inputs
say "5/5 inputs (token map, then A-phase rank cache)"
docker exec "$CONTAINER" pip install -e "$CACHE_MOUNT/tensorfold-tp2"
on_worker "docker exec '$CONTAINER' pip install -e '$CACHE_MOUNT/tensorfold-tp2'"
mkdir -p "$HEAD_CACHE_DIR/temp" "$HEAD_CACHE_DIR/dsv41/tf-ds-rank"
on_worker "mkdir -p '$WORKER_CACHE_DIR/temp' '$WORKER_CACHE_DIR/dsv41/tf-ds-rank'"

TOKEN_MAP_PY='
from tensorfold.families.deepseek_v41.config import Cfg
from tensorfold.families.deepseek_v41.compressed_token_map import build
import json, sys
json.dump(build(Cfg.read(sys.argv[1])), sys.stdout)
'
if [ ! -s "$HEAD_CACHE_DIR/dsv41_token_map.json" ]; then
  docker exec "$CONTAINER" bash -c "PYTHONPATH=$CACHE_MOUNT/tensorfold-tp2/src python3 - \
    $MODELS_MOUNT/$WEIGHTS_SUBDIR > $CACHE_MOUNT/dsv41_token_map.json" <<<"$TOKEN_MAP_PY"
  on_worker "docker exec '$CONTAINER' bash -c \"PYTHONPATH=$CACHE_MOUNT/tensorfold-tp2/src python3 - \
    '$MODELS_MOUNT/$WEIGHTS_SUBDIR' > '$CACHE_MOUNT/dsv41_token_map.json'\"" <<<"$TOKEN_MAP_PY"
fi

if [ -z "$(ls -A "$HEAD_CACHE_DIR/dsv41/tf-ds-rank" 2>/dev/null)" ]; then
  echo "[A] building rank caches on both nodes (rank 0 first) — ~106 GB/rank, takes a while"
  docker exec -d "$CONTAINER" bash -c "
TF_DS_REPLAY=1 TF_DS_PREFILL_CHUNK=2048 TF_DS_RANK_CACHE=$CACHE_MOUNT/dsv41/tf-ds-rank \
TF_DS_RANK_CACHE_READERS=32 TF_DS_TOKEN_MAP=$CACHE_MOUNT/dsv41_token_map.json \
TF_DS_ENGRAM=$MODELS_MOUNT/$ENGRAM_SUBDIR \
$NCCL_ENV \
tensorfold serve $MODELS_MOUNT/$WEIGHTS_SUBDIR \
  --tp $TP_WORLD --rank 0 --master $TP_MASTER_IP --host 127.0.0.1 --port 18891 \
  --context 1048576 --vision --parallel 4 --mtp-drafts 5 \
  > $CACHE_MOUNT/temp/inputs-rank0.log 2>&1"
  sleep 30
  on_worker "docker exec -d '$CONTAINER' bash -c \"
TF_DS_REPLAY=1 TF_DS_PREFILL_CHUNK=2048 TF_DS_RANK_CACHE=$CACHE_MOUNT/dsv41/tf-ds-rank \\
TF_DS_RANK_CACHE_READERS=32 TF_DS_TOKEN_MAP=$CACHE_MOUNT/dsv41_token_map.json \\
TF_DS_ENGRAM=$MODELS_MOUNT/$ENGRAM_SUBDIR \\
$NCCL_ENV \\
tensorfold serve $MODELS_MOUNT/$WEIGHTS_SUBDIR \\
  --tp $TP_WORLD --rank 1 --master $TP_MASTER_IP --host 127.0.0.1 --port 18891 \\
  --context 1048576 --vision --parallel 4 --mtp-drafts 5 \\
  > $CACHE_MOUNT/temp/inputs-rank1.log 2>&1\""
  echo "[A] watch ~/cache/temp/inputs-rank0.log (rank 0 ready = /v1/models 200);"
  echo "[A] when both logs settle: pkill -f 'tensorfold serve' in the container on both nodes"
else
  echo "[A] rank cache already present — skipped"
fi

say "done"
echo "review .env, then ./start.sh"
