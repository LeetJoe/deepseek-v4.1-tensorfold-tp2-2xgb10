# DeepSeek-V4.1-Flash TP2 首次启动手册（2× DGX Spark）

> 写于 2026-10-10；2026-10-12 改为 **head 本机执行 + .env 配置 + `/workspace` 容器路径**。
> 所有准备（容器、引擎、kit、Engram、token map）已在两台机器完成并验证。
> 本手册是唯一需要人工执行的剩余部分：**A 段建缓存（要占两块 GPU）→ B 段启动服务**。
> 会话中断也能照此执行；状态同步看 HANDOFF.md。
>
> **B 段已封装成 `start.sh`，日常重启直接 `./start.sh` 即可。** A 段只在 rank cache 缺失时才需要重做。

## 总约定

- **全部命令在 head 本机的仓库目录里执行**；head 走本地，worker 走 ssh。
- 配置全部走 `.env`（`cp .env.example .env` 后按需改）。`.env.example` 是与真实环境隔离的模板，
  脚本内置默认值即 `.env.example` 的值。
- 容器内固定挂载：`/workspace/models`、`/workspace/cache`；宿主机侧由 `.env` 的
  `HEAD_*_DIR` 决定。`WORKER_*_DIR` / `WORKER_NODEDIR` 默认注释掉，不设就与 head 用同一份值。
- models/cache 下的子路径（kit、token map、rank cache、日志、tf-build、engram、权重）**不变量化**，
  脚本直接拼字面值。

| 项 | 值（默认，见 .env.example） |
|---|---|
| head（rank 0） | `dgxspark@192.168.1.100`，CX7 口 `10.8.8.1`（同时作 TP master ip） |
| worker（rank 1） | `dgxspark@192.168.1.101`，CX7 口 `10.8.8.2` |
| 容器（两台都叫） | `tf-dsv41` = 现役；旧容器已改名 `tf-dsv41-bak` 保留作备用。镜像 `tf-dsv41:2026-10-10`。**必须带 `--device /dev/infiniband`**（只 `-v` 不放进设备 cgroup 白名单，Zig 引擎会 `VerbsFailed`）。创建走 `tf.sh create` / `docker compose up -d` |
| 目录布局 | 宿主 `/home/dgxspark/models`、`/home/dgxspark/cache`；容器内 `/workspace/models`、`/workspace/cache`。源码在 `/home/dgxspark/code`（**不挂进容器**） |
| 容器内模型 | `/workspace/models/DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw`（EXL3 权重）、`/workspace/models/DeepSeek-V4.1-Flash`（engram 原始 shard 47+48） |
| 容器内 kit / token map / rank cache | `/workspace/cache/kit`、`/workspace/cache/dsv41_token_map.json`、`/workspace/cache/dsv41/tf-ds-rank` |
| 容器内二进制 | `/workspace/cache/tf-build/native/bin/tensorfold-native`（服务端）、`/workspace/cache/tf-build/bin/`（跟随者/工具） |
| NCCL 参数 | `.env` 里的 `NCCL_*`（从 glm53-flash-tf 抄的已验证值） |

注意：服务端二进制在 `tf-build/native/bin/`（`zig build native` 的安装位置），**不在** `tf-build/bin/`；
`bin/` 里那个 `tensorfold` 是检查用 CLI，不是服务端。

## 第 0 步：停旧服务、起容器

```bash
cp -n .env.example .env          # 首次
docker stop glm53-flash-tf       # 停 glm53（方式按你平时管理它的办法）
nvidia-smi                       # 确认 GPU 已清空（两台都要看）
ssh dgxspark@192.168.1.101 nvidia-smi
./tf.sh start                    # 两台容器起好（缺失会自动 create）
./tf.sh status
```

head 磁盘剩 551G，rank cache 要 106G，够但别再塞大文件。

## A 段：建 rank cache（每 rank ~106GB，Python 引擎首启动写一次）

> 只在 `~/cache/dsv41/tf-ds-rank` 为空时才需要。A 段的 Python 引擎源码在 `/home/dgxspark/code/tensorfold-tp2`，
> 而容器只挂 `models`+`cache`，所以 A 段要么临时加挂 `/home/dgxspark/code`，要么把 tp2 源码放进 cache。

原理：Zig 引擎只**读** rank cache（`rank_cache.find` 找不到直接报 `NoRankCache`）；
缓存由 deepseek-v41-tp2 Python 引擎第一次启动时写出。两台**同时**各启动一次，rank 0（head）先。

```bash
# A1. 两台都装 Python 引擎（容器内，pypi 可达；只装这一次）
docker exec tf-dsv41 pip install -e /workspace/cache/tensorfold-tp2
ssh dgxspark@192.168.1.101 'docker exec tf-dsv41 pip install -e /workspace/cache/tensorfold-tp2'

# A2. head 先起 rank 0（写缓存模式；日志 /workspace/cache/temp/inputs-rank0.log）
mkdir -p ~/cache/dsv41/tf-ds-rank ~/cache/temp
docker exec -d tf-dsv41 bash -c "
TF_DS_REPLAY=1 TF_DS_PREFILL_CHUNK=2048 TF_DS_RANK_CACHE=/workspace/cache/dsv41/tf-ds-rank \
TF_DS_RANK_CACHE_READERS=32 TF_DS_TOKEN_MAP=/workspace/cache/dsv41_token_map.json \
TF_DS_ENGRAM=/workspace/models/DeepSeek-V4.1-Flash \
NCCL_IB_HCA=roceP2p1s0f1,rocep1s0f1 NCCL_IB_GID_INDEX=5 NCCL_SOCKET_IFNAME=enP2p1s0f1np1 NCCL_NET_PLUGIN=spcx \
tensorfold serve /workspace/models/DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw \
  --tp 2 --rank 0 --master 10.8.8.1 --host 127.0.0.1 --port 18891 \
  --context 1048576 --vision --parallel 4 --mtp-drafts 5 \
  > /workspace/cache/temp/inputs-rank0.log 2>&1"

# A3. 约 30s 后起 worker 的 rank 1（rank 1 连不上会自己重试，看日志）
ssh dgxspark@192.168.1.101 'mkdir -p ~/cache/dsv41/tf-ds-rank ~/cache/temp && docker exec -d tf-dsv41 bash -c "
TF_DS_REPLAY=1 TF_DS_PREFILL_CHUNK=2048 TF_DS_RANK_CACHE=/workspace/cache/dsv41/tf-ds-rank \
TF_DS_RANK_CACHE_READERS=32 TF_DS_TOKEN_MAP=/workspace/cache/dsv41_token_map.json \
TF_DS_ENGRAM=/workspace/models/DeepSeek-V4.1-Flash \
NCCL_IB_HCA=roceP2p1s0f1,rocep1s0f1 NCCL_IB_GID_INDEX=5 NCCL_SOCKET_IFNAME=enP2p1s0f1np1 NCCL_NET_PLUGIN=spcx \
tensorfold serve /workspace/models/DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw \
  --tp 2 --rank 1 --master 10.8.8.1 --host 127.0.0.1 --port 18891 \
  --context 1048576 --vision --parallel 4 --mtp-drafts 5 \
  > /workspace/cache/temp/inputs-rank1.log 2>&1"'

# A4. 盯进度；rank 0 就绪标志 = /v1/models 返回 200，然后停掉两边 Python 引擎
tail -f ~/cache/temp/inputs-rank0.log
ssh dgxspark@192.168.1.101 'tail -f ~/cache/temp/inputs-rank1.log'
docker exec tf-dsv41 curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18891/v1/models
docker exec tf-dsv41 pkill -f "tensorfold serve" || true
ssh dgxspark@192.168.1.101 'docker exec tf-dsv41 pkill -f "tensorfold serve" || true'

# A5. 验证（两台都要，应各有 rank{0,1}of2-*.bin ~106G）
ls -lh ~/cache/dsv41/tf-ds-rank/
ssh dgxspark@192.168.1.101 'ls -lh ~/cache/dsv41/tf-ds-rank/'
```

## B 段：启动 Zig 引擎服务

> 已封装：**`./start.sh`**（rank 1 先、rank 0 后、等 ready、发 smoke）。下面是它展开后的等价手工命令。
> **不启用跨机 RDMA ring**（解码 gather 走 NCCL 回退），且引擎已打 `prompt.zig` 的 `rb` 取偶补丁。
> 切勿把 `--rdma` / `TF_RDMA_DEVICES` 加回来（ring 目前在这两台会 `error.Failed`，见常见故障）。

```bash
# B1. worker 先起跟随者（tf-dsv41-lanes；跟随者不需要 --requests）
ssh dgxspark@192.168.1.101 'docker exec -d tf-dsv41 bash -c "
TF_DS_REPLAY_FLOOR=1 \
NCCL_IB_HCA=roceP2p1s0f1,rocep1s0f1 NCCL_IB_GID_INDEX=5 NCCL_SOCKET_IFNAME=enP2p1s0f1np1 NCCL_NET_PLUGIN=spcx \
/workspace/cache/tf-build/bin/tf-dsv41-lanes \
  /workspace/models/DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw \
  /workspace/cache/dsv41/tf-ds-rank 1 2 10.8.8.1 29620 /workspace/cache/kit \
  --engram /workspace/models/DeepSeek-V4.1-Flash \
  --token-map /workspace/cache/dsv41_token_map.json \
  --pool 1048576 --graphs 1 --side 1 --prefetch 1 --aio 1 \
  > /workspace/cache/temp/lanes.log 2>&1"'

# B2. 等十几秒，head 起 rank 0 服务端（注意二进制是 native/bin/tensorfold-native）
sleep 15 && docker exec -d tf-dsv41 bash -c "
TF_DS_REPLAY_FLOOR=1 TF_TP_WORLD=2 TF_TP_MASTER=10.8.8.1 TF_TP_PORT=29620 \
TF_DS_RANK_CACHE=/workspace/cache/dsv41/tf-ds-rank \
TF_DS_KIT=/workspace/cache/kit TENSORFOLD_CUDA_KERNELS=/workspace/cache/kit/aot \
TF_DS_ENGRAM=/workspace/models/DeepSeek-V4.1-Flash \
TF_DS_TOKEN_MAP=/workspace/cache/dsv41_token_map.json \
TF_DS_GRAPHS=1 TF_DS_HC_SIDE=1 TF_DS_L2_PREFETCH=1 TF_DS_ENGRAM_AIO=1 \
NCCL_IB_HCA=roceP2p1s0f1,rocep1s0f1 NCCL_IB_GID_INDEX=5 NCCL_SOCKET_IFNAME=enP2p1s0f1np1 NCCL_NET_PLUGIN=spcx \
/workspace/cache/tf-build/native/bin/tensorfold-native serve \
  /workspace/models/DeepSeek-V4.1-Flash-UNCENSORED-EXL3-2.9bpw \
  --host 0.0.0.0 --port 8888 --name DeepSeek-V4.1-Flash-TF \
  --context 1048576 --parallel 4 --thinking --max-tokens 32768 \
  --temperature 1.0 --top-p 0.95 --top-k 20 --backend cuda \
  > /workspace/cache/temp/serve.log 2>&1"

# B3. 验证
sleep 30; docker exec tf-dsv41 curl -s http://127.0.0.1:8888/v1/models
curl -s http://127.0.0.1:8888/v1/chat/completions -H "Content-Type: application/json" \
  -d "{\"model\":\"DeepSeek-V4.1-Flash-TF\",\"messages\":[{\"role\":\"user\",\"content\":\"你好，用一句话自我介绍\"}],\"max_tokens\":64,\"temperature\":0}"
```

说明：

- `--host 0.0.0.0` 是为了局域网可访问；要加鉴权就 `--api-key-file <文件>`（每行一个 key）。
- 首次启动到 ready 实测约 120–150 s（冷启动）。
- **长 agentic 会话别把 temperature 设 0**（会陷入 reasoning 循环）；要确定性只用于评测。
- **引擎已打补丁**：`prompt.zig:941` 的索引器行块步长 `rb` 取了偶，否则约 20 万 token 的长上下文会 500
  `MissingTritonVariant`。原始文件备份为 `prompt.zig.bak`；若从原始源码重编必须重打。
- **graph 开或关都行**：解码是 GPU/带宽瓶颈，实测开关图差异在噪声内（~1 tok/s）。当前用 `--graphs 1`。

## 停止 / 重启

```bash
./start.sh            # 起服务（幂等）
./stop.sh             # 停引擎，容器保留
./stop.sh all         # 连容器一起停
./tf.sh status|logs   # 看状态
```

重启 = 再跑 `./start.sh`（rank cache 已在，不用再做 A 段）。

## 常见故障

- **`error.Failed`（rank0 返回 500 `reason=error (Failed)`；rank1 日志 `{"follow_refused":"Failed"}`）**：
  跨机 RDMA ring（`rdma.zig` 的 `Ring.failure()`）失败。**按 B 段（不配 `--rdma` / `TF_RDMA_DEVICES`）即可**
  ——解码 gather 自动回退 NCCL。ring 在这两台会失败，修好前不要再加回 RDMA 参数。
  此前 `serve.log` 伴随的 `CUDA_ERROR_STREAM_CAPTURE_UNJOINED (904)` 是假象，不是 graph 的问题。
- **`MissingTritonVariant`（`_index_score_rows`，约 >13 万 token 的长上下文）**：缺 `prompt.zig` 的 `rb` 取偶
  补丁。两台已打（`prompt.zig.bak` 是原文件）；从原始源码重编需重打 `... & ~@as(usize, 1)`。
- **换/覆盖引擎二进制**：`tf-build/` 是 root 所有，必须在容器里以 root 覆盖
  （`docker exec tf-dsv41 cp 新 旧`），用 ssh 的 `dgxspark` 直接 `cp` 会 `Permission denied` 且旧二进制照跑。
- rank 1 起不来、报 NCCL/DistStore：确认 rank 0 先起（B 段 lanes 先于 serve）。
- NCCL 报 plugin 加载失败：去掉 `NCCL_NET_PLUGIN=spcx` 再试（插件在两台镜像里都有，加载失败不致命）。
- `error.NoRankCache` / `error.NoTokenMap`：路径不对，对照 `.env` 与上表。
- `VerbsFailed`（Zig 引擎起不来）：容器没放行 RDMA 设备。`docker exec tf-dsv41 ibv_devinfo -d roceP2p1s0f1`
  应显示 PORT_ACTIVE；不显示就 `./tf.sh create` 重建（A 段产物在宿主机盘上，不受影响）。
- `verify_kit.sh` 失败：kit 文件被改动，回 HANDOFF 记录里找原因。
- 显存不够：确认 glm53 确实停了、`nvidia-smi` 无残留进程。
