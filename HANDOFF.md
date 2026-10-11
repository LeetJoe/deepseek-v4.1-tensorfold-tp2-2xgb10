# Handoff

Updated: 2026-10-12 by account A (LeetJoe / personal)
Branch: main

## Doing now

**Reorg COMPLETE and the service is UP on the new layout, verified.** Layout, container name, head-only scripts,
`.env` config and `/workspace` mounts are all live; the moves ran and `./start.sh` started cleanly on both nodes.
Verified 2026-10-12: containers `tf-dsv41` Up on both, engines running with `/workspace` paths, old `code/kit` /
`code/tf-build` / `code/cache` / `work/temp` gone, `/v1/models` 200, smoke returns a real completion, `tf-dsv41-bak`
spare is idle (no engines). Serving config unchanged: rank caches on disk, patched `prompt.zig`, **CUDA graphs ON,
cross-node RDMA ring OFF** (decode falls back to NCCL). HANDOFF kept local-only per user.

## Done since last handoff

- **2026-10-12 (ops): reorg executed on both nodes and the service restarted on the new layout — VERIFIED.**
  - User stopped the old engines in `tf-dsv41-bak`, ran the move commands (with the container name corrected to
    `tf-dsv41-bak`), then `./start.sh`. Everything came up: both containers `tf-dsv41` Up, rank1 then rank0 engines
    on `/workspace/...` paths, `/v1/models` 200, smoke 200 with a real reply.
  - Old dirs (`code/kit`, `code/tf-build`, `code/cache`, `work/temp`) are gone; new ones (`cache/kit`, `cache/tf-build`,
    `cache/dsv41_token_map.json`, `cache/temp`) present on both.
  - `tf-dsv41-bak` remains as an idle spare (no engines).

- **2026-10-12 (ops, step 3): minimise required edits.**
  - `WORKER_MODELS_DIR` / `WORKER_CACHE_DIR` / `WORKER_NODEDIR` now DEFAULT to the head's values
    (`$HEAD_*`, `$SRC`) — only set them if the worker differs.
  - `.env.example` reordered: section 1 = the values you normally edit (left active), section 2 = per-worker
    overrides (commented), section 3 = defaults (commented, since they already equal the built-in defaults).
  - Only section 1 is active, so a plain `cp .env.example .env` still works and touches nothing by default.
  - `start.sh` subpath variables were already inlined in step 2's follow-up; only `WEIGHTS_SUBDIR` /
    `ENGRAM_SUBDIR` remain as vars.

- **2026-10-12 (ops, step 2): parameterize + head-only + `/workspace` mounts.**
  - Container mount points are now FIXED at `/workspace/models` and `/workspace/cache`; only the host side is
    configurable, via `HEAD_MODELS_DIR` / `HEAD_CACHE_DIR` (worker overrides them to `WORKER_*` at run time;
    the old separate `HOST_*` vars were dropped).
  - New `.env.example` (all values = current production values) covering: node SSH/IP/CX addresses, per-node host
    dirs, container/image names, listen host/port, TP master port, weights/engram folder names, NCCL, engine params,
    readiness timeouts. `.env` is optional (built-in defaults) and is `.gitignore`d. TP master ip = `HEAD_CX_IP`
    (no separate var); other subpaths (kit, token map, rank cache, logs, tf-build) are literals in the scripts.
  - `docker-compose.yml` interpolates everything from env with defaults; `name`/`container_name`/`image`/mounts all
    parameterized.
  - `start.sh` / `stop.sh` / `tf.sh` rewritten head-only: they `source .env`, set defaults, and hard-fail if not on
    the head. Worker work happens inside these head scripts over ssh. All container-side paths use `/workspace/...`.
  - `LAUNCH.md` rewritten to the `/workspace` paths + head-local style, A段 kept manual (its Python-engine source
    lives in `~/work/code`, which is not mounted — noted there).
  - `bash -n` clean on all three scripts; `docker compose config` renders clean with and without env overrides.
  - `_bak` files left untouched.

- **2026-10-12 (ops, step 1 of the head-local switch):** `docker-compose.yml` made head-runnable — paths are now
  `$HOME`-relative and the header says to run it on the head (tf.sh still scp's it to the worker for the worker's
  container). Scripts: only the head-related parts touched — a stderr note when not on the head, and `tf.sh ensure`
  now runs the head side straight from this repo dir instead of copying to NODEDIR (worker still copied).
  `docker compose config` renders clean, `bash -n` clean. Nothing else changed, on purpose (step by step).

- **2026-10-12 (ops): directory layout flattened + container renamed to `tf-dsv41`.**
  - New layout: `~/work/models` (unchanged) and `~/work/cache` (everything else). Moved targets: `code/tf-build` →
    `cache/tf-build`, `code/kit` → `cache/kit`, `code/cache` → `cache/` (its `dsv41_token_map.json` lands at
    `cache/dsv41_token_map.json`), `work/temp` → `cache/temp`. `code/tf-build-new` (staging) stays under `code/`.
  - Repo files updated to the new paths: `start.sh`, `stop.sh`, `tf.sh`, `LAUNCH.md`, `HANDOFF.md`.
  - `docker-compose.yml`: container_name/service/project → `tf-dsv41`, and the single `~/work` mount replaced by
    two mounts (`~/work/models`, `~/work/cache`). The previously-live container was RENAMED by the user to
    `tf-dsv41-bak` and kept as a spare/backup (it still mounts the whole `~/work`, so it works either way).
  - `tf.sh start` now auto-creates `tf-dsv41` from the image via compose if it is missing (previously it only
    started an existing container, so a fresh name would have no-op'd).
  - `bash -n` clean on all three scripts.
  - **Move commands (user runs these, both nodes — root inside the OLD container, same fs so rename only):**

    ```bash
    # on 120 AND on 121:
    docker exec tf-dsv41 bash -c '
      set -e
      mkdir -p /home/neosong/work/cache
      mv /home/neosong/work/code/cache/dsv41_token_map.json /home/neosong/work/cache/
      rmdir /home/neosong/work/code/cache
      mv /home/neosong/work/code/tf-build /home/neosong/work/cache/tf-build
      mv /home/neosong/work/code/kit      /home/neosong/work/cache/kit
      mv /home/neosong/work/temp          /home/neosong/work/cache/temp
    '
    ```

- **2026-10-10 (ops): containers committed + docker-compose management (reuse-first).**
  - Both containers committed to image `tf-dsv41:2026-10-10` (120 `079befc9d6a7`, 121 `655f9413ee41`; ~11.4GB
    content). `docker commit` captures only the container rootfs (apt/pip); weights, rank cache, engine and kit
    stay on the `~/work` bind mount, so the image alone is not self-contained — it must be run with that mount.
  - Added at the repo root: `docker-compose.yml`, `tf.sh` (container lifecycle; **reuse-first, never removes**),
    `start.sh` (stop engines → reuse container → start rank 1 then rank 0 → wait ready → smoke), `stop.sh`
    (`stop.sh all` also stops the container). Run them on 120; `tf.sh` auto-detects local-head vs ssh.
  - Verified on 2026-10-10: `start.sh restart` reused the same container (Created timestamp unchanged) and
    reached ready + smoke. Deployed copy on 120 at `~/work/compose/` (repo-root copies are the canonical ones).
  - Root cause of a first failed attempt: head-detection pattern missed when `hostname -I` listed
    `192.168.3.120` first; fixed by padding the match with spaces.

- **2026-10-10: A段 + B段 run; two B-section bugs found, fixed and verified (service now serving).**
  - **B3 `cudafail`/`server_error` root cause = the decode's cross-node RDMA ring, NOT CUDA graphs.** The ring
    fails (`error.Failed`; the only place that error is raised is `rdma.zig Ring.failure()`). The
    `cuStreamEndCapture: CUDA_ERROR_STREAM_CAPTURE_UNJOINED (904)` in `serve.log` is a secondary artifact: a
    captured decode stretch returns early on the ring's `error.Failed`, and `round.Graphs.run`'s cleanup calls
    `cuStreamEndCapture` with a forked helper stream unjoined → prints UNJOINED and is discarded. Proof: eager
    (`TF_DS_GRAPHS=0`) fails identically; `tf-dsv41-rdma-bench` reproduces `error: Failed` on both nodes on each
    CX7 port alone and both together; both ports PORT_ACTIVE, GID index 5 = RoCEv2 with the right IPv4, port error
    counters 0. NCCL over the same ports (prefill) works.
  - **Workaround in place:** run with no RDMA ring — rank 1 drops `--rdma`, rank 0 drops `TF_RDMA_DEVICES`.
    `prompt.gatherF32` then uses the NCCL all-gather (same bytes). Decode is GPU/bandwidth-bound: graphs on vs off
    ≈ 47 vs 50 tok/s on a 700-token prose gen (noise), matching the lane report ("CUDA graphs alone gained
    ~1 tok/s"). Current config: graphs ON, ring OFF, side/prefetch/aio ON.
  - **Long-context `MissingTritonVariant` (second, independent bug).** Agent turns with ~212K-token context got
    `500 reason=error (MissingTritonVariant)` for `_index_score_rows`. Cause: `prompt.zig` indexer row-block stride
    `rb = max(16, min(n, 2^24/n_comp_end))` can be ODD; the per-block view `vr = ch.vis + r0*8` is then only
    8-byte aligned on odd blocks, and all 23 `_index_score_rows` kit variants assume VIS is 16-aligned. The
    47a8910d fallback may not relax an alignment assumption → no variant fits. Reproduced with a fresh
    212,064-token prompt (`n=212064 rows=49 nt=3314`, VIS 16-aligned false); 86K-token prompts (rb even) passed.
  - **Fix + rebuild (both nodes).** `prompt.zig:941` → append `& ~@as(usize, 1)` (force `rb` even). Source backups
    `prompt.zig.bak`. Rebuild inside the container: `cd ~/work/code/TensorFold &&
    ~/work/tools/zig-aarch64-linux-0.17.0/zig build install native -Dtarget=aarch64-linux-gnu
    -Doptimize=ReleaseSafe -Dnvcc=/usr/local/cuda/bin/nvcc -Dsm=121 --prefix ~/work/code/tf-build-new` (staging;
    `tf-build/` files are root-owned, so copy them in as root with `docker exec tf-dsv41 cp`). The 212,064-token
    prompt now returns 200; the log shows the intended exact fallback
    `warning: _index_score: ... runs variant ... (assumes less)`.

- (pre-launch) Container `tf-dsv41` created on BOTH nodes (192.168.3.120 = head spark-cf5d-sc00, 192.168.3.121 = worker
  spark-36a3-sc01) from `nvcr.io/nvidia/pytorch:26.07-py3`, flags per recipe: `--network host --ipc host
  --ulimit memlock=-1 --cap-add IPC_LOCK --gpus all`, `/dev/infiniband` + `$HOME/work` mounted, `sleep infinity`.
  Verified inside both: GB10 GPU, nvcc CUDA 13.3, Python 3.12, torch 2.13.0a0+9186a08b2c.nv26.07, aarch64, RDMA.
- **Gotcha:** nodes initially had DIFFERENT images under the same 26.07-py3 tag (120 stale `7531d90b…`). Re-pulled
  on 120; both now run identical image `sha256:2140e699b3beaf7f96a0081fd9c9406bc3832b435cdb60dfa2d261f7d2f34a1c`.
- Fetched `bertholomus/deepseek-v41-zig` (engine HEAD `4e80f05e`, includes `ce20a545` + kit builders) and
  `deepseek-v41-tp2` into local `~/work/code/TensorFold` as remote `bertholomus`.
- Downloaded Zig 0.17.0 aarch64-linux locally (ziglang.org direct dropped once; retry with --retry worked) and
  rsynced zig + sources + `kit/` to both nodes: `~/work/tools/zig-aarch64-linux-0.17.0/`, `~/work/code/TensorFold`,
  `~/work/code/tp2-src`, `~/work/cache/kit`.
- **Engine built on BOTH nodes** inside the containers (zig build install native, ReleaseSafe, sm_121, nvcc):
  OK on 120 and 121, only a harmless nvcc warning; binaries in `~/work/cache/tf-build/bin/` on each node
  (tensorfold, tf-dsv41-lanes, + dsv41 check tools), `--help` verified.
- Kit generated+verified on 120: RoPE tables via `make_rope.py` (in-container, PYTHONPATH=tp2-src/src, CPU, ~min);
  gate bias downloaded from the kit's HF mirror and matched MANIFEST (`0cbdebfb…`); `verify_kit.sh` → **221 files
  OK on 120**; RoPE tables rsynced 120→121 (over 10.0.0.x); **221 files OK on 121**.
- Engram shards (47+48, 101.5GB each) downloaded complete on 120 by the pre-existing modelscope loop (finished
  13:12; sizes match HF byte for byte). **`tf-dsv41-engram-check` on 120 PASSES**: both layers (1, 14), 4096 random
  rows, buffered/O_DIRECT/AIO paths byte-identical, direct FDs active. So `ENGRAM_DIR =
  ~/work/models/DeepSeek-V4.1-Flash` is valid as-is — the Zig engine reads the ORIGINAL safetensors shards
  (engram_io.zig scans `*.safetensors` for `engram.embed` weight/scale); no packing step.
- **Format note:** the OTHER recipe on these nodes (`~/work/code/deepseek-v41-tensorfold-spark`,
  pack_engram.py) packs per-rank `DSV41EN1` bins for its own engine — NOT compatible with ours and not needed.
  Its download feeds us too; one copy of the raw shards serves both engines.
- rsync of both shards 120→121 (10.0.0.x, CX7) COMPLETE ~13:23; sizes on 121 byte-exact (101,535,150,936 /
  101,537,926,640). **`tf-dsv41-engram-check` on 121 PASSES** (2 layers, 3 paths, all_equal). Both nodes are fully
  prepped: engine + kit + engram + token map.

- **Token map generated on BOTH nodes (CPU only, no GPU):** `dsv41_token_map.json` in each node's
  `~/work/cache/`, 99,092 entries == `engram_cvocab` asserted. Script: `~/work/cache/temp/make_token_map.py`
  (uses tp2-src's `compressed_token_map` + `Cfg.read`; tokenizer.json of the EXL3 checkpoint).
- **The one GPU-dependent input left: the rank cache** (`rank{r}of{w}-*.bin`, ~106GB a rank). The Zig engine only
  READS it (`rank_cache.find` -> `error.NoRankCache`); it is written by the deepseek-v41-tp2 Python engine on its
  first boot — `build_inputs.sh` does this by starting that engine on both nodes at once (rank 0 first), so it must
  wait until the glm53 service frees both GPUs. Our tp2-src checkout can be pip-installed inside the tf-dsv41
  container to run it (build_inputs.sh's IMAGE env is just the tp2 engine's image).

## Next steps (in order)

0. ~~Finish the 2026-10-12 reorg~~ — **DONE, service UP and verified.** Restart from now on = `./start.sh` on the
   head. `tf-dsv41-bak` spare is idle; delete it once you trust the new setup (its engines are already stopped).
0b. **A段 note:** the A段 Python-engine source (`~/work/code/tensorfold-tp2`) is not mounted into the container, so a
   rank-cache rebuild needs a temporary `~/work/code` mount or a copy into `~/work/cache`. Consider making that a
   `.env`-driven optional mount.
1. **Report/fix upstream** (`bertholomus/TensorFold`): the indexer `rb` parity fix (Zig-port-specific — the
   Python lane never hits it because Triton JIT-compiles the misaligned variant) and the RDMA ring failure.
2. **RDMA ring diagnosis** (optional; the service works without it). To get the verb status: add a print of `why`
   in `rdma.zig fail()` (or print `r.failure()` on `rdma_bench_main`'s error path), rebuild, rerun
   `tf-dsv41-rdma-bench RANK 2 10.0.0.1 <rdma fatbin> roceP2p1s0f1,rocep1s0f1` (fatbin at
   `~/work/code/TensorFold/.zig-cache/o/2420e0980417e3a87a1317d037627204/dsv41_rdma.fatbin`), then decide QP
   params vs upstream. If resolved, re-add `--rdma`/`TF_RDMA_DEVICES` in LAUNCH.md.
3. **Runbook:** `LAUNCH.md` (local-only, Chinese) is updated for the current working config (no RDMA ring,
   patched engine). Restart = re-run B1/B2 only (rank cache already on disk).

## Open questions / blockers

- RDMA ring still fails with a bare `error.Failed` (verb status not yet printed); service runs fine without it
  (NCCL decode gather). See Next steps #2.
- Push rights: this account cannot push to `bertholomus/*`; per user, everything stays local anyway — no commits,
  no pushes. User handles git themselves.
- 120 disk: 551G free — enough for its 106G rank cache, but don't add anything big on 120.

## Gotchas (things that broke, decisions made and why)

- **`~/work/code` is NOT mounted into `tf-dsv41`** (only `models` + `cache`). Runtime paths are all under
  `cache`/`models`, so serving is fine — but an in-container REBUILD no longer sees the source. The documented
  rebuild (`cd ~/work/code/TensorFold && zig build …`, and `~/work/tools/zig-…`) will fail until you either add a
  third mount for `~/work/code` or rebuild from the host. Note this before the next rebuild.
- **The scripts are head-only and HARD-FAIL off the head** (they check `hostname -I` against `HEAD_IP`). Worker work
  is driven from inside the head scripts over ssh. Config lives in `.env` (see `.env.example`); never edit values
  inline in the scripts — change `.env`.
- **`.env.example` is a GENERIC template, decoupled from the real environment** (user, IPs, dirs there are
  placeholders: `dgxspark` / `192.168.1.x` / `/home/dgxspark/...`). The real values live in `.env` — fill it with
  the actual ones (`neosong`, `192.168.3.120/121`, `10.0.0.1/3`, `/home/neosong/work/{models,cache}`). The scripts'
  built-in defaults mirror `.env.example`, not the live box. The on-node move commands below still use the real
  `/home/neosong/work` paths.
- **Worker config is optional by design.** `WORKER_MODELS_DIR` / `WORKER_CACHE_DIR` / `WORKER_NODEDIR` fall back to
  the head's values; only set them if the worker genuinely differs. `.env.example` keeps them commented.
- **Container paths are fixed `/workspace/models` + `/workspace/cache`.** Only the host side is parameterized
  (`HEAD_*_DIR` / `WORKER_*_DIR`). Any new in-container path must use `/workspace/...`.
- **`tf.sh ensure` scp's compose **and** `.env` to the worker** (`WORKER_NODEDIR`). If `.env` is absent it is simply
  skipped and the worker's compose falls back to its own defaults — so keep host dirs correct on the worker side.
- **Moves are done; they ran via `docker exec` as root** because `~/work/code/cache` / `code/tf-build` were
  root-owned and `sudo` needs a password on the nodes. Note the move command must name the container that currently
  exists — at the time that was `tf-dsv41-bak`, not `tf-dsv41`.
- **`tf-dsv41-bak` is an idle spare** (still mounts the whole `~/work`); `tf-dsv41` is the LIVE name. Its engines are
  stopped. Safe to delete once you trust the setup.
- **`./stop.sh` only targets `tf-dsv41`, NOT the bak.** Both use `--network host`, so port 8888 collides — if the bak
  ever runs engines again, stop them separately or they fight over the port.
  `tf.sh status` anchors on `^tf-dsv41$` so the bak does not show up.
- **The B3 `cudafail` and the graph `CUDA_ERROR_STREAM_CAPTURE_UNJOINED` are red herrings.** They are the
  aborted-capture cleanup of a decode stretch that first failed in the RDMA ring (`error.Failed`). Do not chase
  CUDA graphs for this; look at `rdma.zig Ring.failure()`. The ring fails on these nodes even though verbs work
  and NCCL-over-RoCE works — run without it (omit `--rdma` / `TF_RDMA_DEVICES`) until diagnosed.
- **Long contexts need the indexer `rb` even.** `prompt.zig:941` must end with `& ~@as(usize, 1)`, or a
  misaligned per-block `vis` view makes `_index_score_rows` raise `MissingTritonVariant` (a 500) at ~>131K-token
  contexts. Both nodes are built with this patch; `prompt.zig.bak` holds the pristine file. Re-apply after any
  fresh source checkout.
- **`tf-build/` binaries are root-owned** (installed by the container). Overwrite/swap them as root inside the
  container (`docker exec tf-dsv41 cp ...`), not over ssh as `neosong` (that gives `Permission denied` and silently
  leaves the old binary running).
- **VerbsFailed on first launch (2026-10-10): the tf-dsv41 container lacked `--device /dev/infiniband`.** A `-v`
  mount alone does not put the uverbs nodes into the device cgroup allowlist, so `ibv_open_device` failed in
  the container. Phase A hid it (the Python engine downgrades to NCCL gathers: "gathers stay on NCCL"); the Zig
  engine hard-fails. FIXED 2026-10-10: both containers recreated with `--device /dev/infiniband`, ibv_devinfo
  verified PORT_ACTIVE inside. Phase A outputs (99G rank caches both nodes) are on host disk and unaffected.
  LAUNCH.md updated with the recreate command.
- **Server binary location**: `zig build native` installs the SERVER to `<prefix>/native/bin/tensorfold-native`
  (its --help shows the recipe's exact serve flags). `<prefix>/bin/tensorfold` is a DIFFERENT binary (the
  run/segments/lanes check CLI, zig/src/main.zig) — don't serve with it. `tf-dsv41-lanes` needs `--requests FILE`
  only as a rank-0 gate tool; as the rank-1 follower it runs without it.
- Same-tag image divergence between nodes — always compare `docker inspect` RepoDigests on both before serving.
- ziglang.org download can drop mid-transfer; curl --retry --retry-all-errors resumes fine.
- rsync of a dir named `kit` without trailing slashes produced `kit/kit` on the first try — flattened by hand;
  use `src/` + `dest.../kit/` form.
- `make_bias_vl.py` needs the ORIGINAL checkpoint's shards, which we don't have (only 47 there) — took the file
  from the released kit's HF mirror instead, sha256-verified. If regenerating from source is ever needed, shard
  3 (and whichever others hold `bias_vl`) must be downloaded.
- Sparks cannot reach github/huggingface (HTTP 000) but modelscope.cn works — the running download uses it.
