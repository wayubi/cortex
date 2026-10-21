# Plan: Faster cold model loads without pinning models in RAM

**Date:** 2026-10-21
**Status:** Option 1 applied 2026-10-21 to both routers (`load-mode = mmap+mlock`); its decode/prefill
re-bench (Option 1 step 5) is still pending a quiet window. Options 2–5: plan only, to be reviewed one by one.

Option 1 load measurements (3 runs each; cold = the GGUF evicted from the page cache first):

| | no-mmap + mlock | mmap+mlock |
|---|---|---|
| gemma-12b cold / warm | 21.2, 22.2, 73.4 s / 6.1, 6.1, 6.2 s | 21.3, 21.4, 21.5 s / 5.9, 6.0, 6.1 s |
| tiel q4 128k cold / warm | 59.7, 63.1, 218.4 s / 20.2, 21.4, 27.2 s | 56.9, 57.0, 57.9 s / 13.5, 13.7, 14.2 s |
| tiel RAM while loaded | 16.1 GB anon + 22.4 GB cache | 22.9 GB (the cached file) |
| tiel VmLck | 0 | 20.3 GB |

Cold loads stay disk-bound (the 73 s and 218 s outliers were served by the slow mirror).
**Audience:** an implementing agent. Read each option's "Before you start" and stop where it says to ask.
**Constraint:** no model is pinned in RAM ahead of use (no `vmtouch -l`, no tmpfs copies). RAM may only
be held by the model that is loaded.

---

## 0. Why this plan exists

A switch to `glm-4.7-30b-a3b-flash-q4-128k-think-coder` on 2026-10-21 took **2 min 47 s** to load
(`load_model: loading model` at 0:00.36 → `model loaded` at 2:47.9 in the child log). The same
day `gemma-4-12b-q4-qat-mtp-32k-think` loaded in **6.5 s** because its file was still in the page cache.

Measured causes:

| Finding | Evidence |
|---|---|
| Cold loads read the whole GGUF from `/mnt/md2` | GLM: 17.5 GB in 167 s ≈ 105 MB/s |
| `/mnt/md2` is btrfs RAID1 over two SATA SSDs that read very differently | `sdb` Crucial BX500: ~520 MB/s on any data. `sdc` KingSpec P3: ~270 MB/s fresh, 100–120 MB/s on data a few weeks old (O_DIRECT reads of each mirror, 2026-10-21) |
| btrfs picks the mirror per process (`read_policy` = `pid`, the only policy this kernel offers) | Roughly half of all cold loads are served by the slow drive |
| `[*]` sets `no-mmap = true` and `mlock = true` | Every loaded model is copied into anonymous memory **and** stays in the page cache: ~2× its size in RAM |
| `mlock` does nothing today | Every `llama-server` child shows `VmLck: 0 kB` despite `--mlock` and an unlimited memlock ulimit. llama.cpp only locks a mapping, and with `no-mmap` there is none |
| The loaded model can be swapped out | `vm.swappiness = 60`, ~25 GB of swap in use |
| Variants of one model reload the same file | `-think` / `-think-coder` / plain are separate presets. The coordinator unloads on any model-name change, so moving between siblings reloads identical weights |

No git history or doc records why `no-mmap` was chosen (it predates `0aa5f60`).

## 1. Baseline first (all options use it)

Before changing anything, record a baseline so each option's gain is measured rather than assumed.

1. **Load time** comes from the child log: the difference between its `load_model: loading model` and
   `llama_server: model loaded` timestamps (the `[port] M.SS.mmm` prefix is time since the child started).
2. **Cold vs warm.** "Cold" means the model's GGUF is not in the page cache. Evict one file, and only that
   file, without touching anything else:
   ```
   python3 -c "import os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); os.posix_fadvise(fd,0,0,os.POSIX_FADV_DONTNEED)" <gguf>
   ```
   Check with `fincore <gguf>` (should show ~0 cached). Never run `echo 3 > /proc/sys/vm/drop_caches`:
   it evicts every service's cache on the host.
3. **Which mirror served the load** matters (§0), so measure each case three times and report all three.
4. Record for each load: wall time, `fincore` before/after, and the child's `VmRSS`, `VmLck`, `VmSwap`
   from `/proc/<pid>/status`.
5. Test models: `gemma-4-12b-q4-qat-mtp-32k` (GPU-resident, 6.7 GB) and
   `tiel-coder-35b-a3b-q4-mtp-128k-think-coder` (CPU-resident MoE, 22 GB, afghanica's production model).
6. Only run this while cortex is idle. Check `curl -s localhost:8080/availability` first: `busy` false and
   `human_pending` false. A load you trigger evicts whatever is resident.

---

## Option 1: mmap + mlock instead of no-mmap (recommended first)

**Goal:** a loaded model costs its size in RAM once, a reload of a still-cached file takes about as long
as copying its GPU layers to VRAM, and the loaded model can no longer be swapped out.

**Change:** in `llama-cpp/models.ini` `[*]`, replace
```
no-mmap          = true
mlock            = true
```
with
```
load-mode        = mmap+mlock
```
`--mlock`, `--mmap` and `--no-mmap` are deprecated in the current build. `llama-server --help` lists
`--load-mode` with `auto | none | mmap | mlock | mmap+mlock | dio`. Do the same in
`prism-llama-cpp/models.ini` only after llama-cpp passes, and confirm the fork's `--help` has the flag.

**Before you start:** confirm no section overrides `no-mmap`, `mmap`, `mlock` or `load-mode`
(`grep -nE '^(no-mmap|mmap|mlock|load-mode)' */models.ini` should only hit `[*]`).

**Steps:**
1. Run the §1 baseline for both test models.
2. Make the change and `docker compose restart llama-cpp`.
3. Repeat the §1 measurements, cold and warm.
4. Check the child's `VmLck` is now roughly the size of its CPU-resident weights (non-zero), and `VmSwap` is 0.
5. Re-bench decode and prefill on both test models: `./tools/bench.sh bench <model>` (bench only, no
   re-tune). Compare against the committed JSONs.
6. On the CPU-resident model, also run a 4000-token decode right after a **cold** load, to catch page
   faults on expert weights the warm-up did not touch.

**Accept if:** decode and prefill are within run-to-run noise (2–4%) of the committed records, warm reloads
are clearly faster than baseline, and `VmLck` > 0. **Revert if:** decode drops beyond noise, or a cold first
request stalls noticeably more than baseline.

**Risks:**
- **mlock and RAM:** with `mmap+mlock` the CPU-resident weights are locked while the model is loaded. That
  is RAM the model already uses today (as its anonymous copy), so nothing new is held, but it cannot be
  reclaimed under pressure. Check free memory stays healthy while the largest model is loaded.
- **GPU layers:** after `-fit` uploads layers to VRAM, their pages in the mapping should not stay locked.
  Check that `VmLck` is near the CPU share of the model, not the whole file. If it is the whole file,
  report the numbers and stop.
- **Cache size:** the page cache still holds recently used models, but the kernel may drop them under
  memory pressure. That is intended (no pinning).

**Docs:** update the `[*]` comment, and add a short note to `AGENTS.md` ("Gotchas") saying why
`mmap+mlock` replaced `no-mmap`, with the numbers from this run.

---

## Option 2: Serve all variants of a model from one loaded instance

**Goal:** moving between `-think`, `-think-coder`, `-coder` and plain variants of the same weights and ctx
does not unload and reload the model.

**Why the coordinator alone cannot do it:** llama.cpp's router runs a separate process per preset. If the
coordinator skipped the unload, the router would start a second copy of the same model and run out of VRAM.

**Design: rewrite sibling requests onto the family head.** In openresty, before coordination:
1. Look up the requested `model`. If it is a family sibling, rewrite the body's `model` to the family head's
   name, the same family `bench.sh` uses (`family_scan`).
2. Add the sibling's own sampling defaults to the body for any key the client did not set:
   `temperature`, `top_p`, `top_k`, `min_p`, `presence_penalty`, `repeat_penalty`.
3. Add the sibling's reasoning setting as `chat_template_kwargs.enable_thinking` (true for
   `reasoning = on`, false for `off`), unless the client set it.
4. The coordinator then sees one model name per family and never switches between siblings.

**Family map:** do not reimplement `family_scan` in Lua. Add `tools/gen_families.py` that reads both
models.ini files with the same rules as `family_scan` (`FAMILY_FREE`, `[*]` fallback) and writes
`openresty/families.json`:
`{ "<sibling>": { "head": "<head>", "params": {...}, "enable_thinking": true|false } }`.
openresty re-reads it at most every 5 s, as `cortex.target_for` does for the prism ini. Mount it like
`prism-models.ini` (a new volume: the first deploy needs `docker compose up -d openresty`). Call the
generator from `bench.sh` whenever it edits a models.ini, and document running it after hand edits.

**Before you start, verify on one family by hand (stop and report if any check fails):**
1. llama-server honours a request-level `chat_template_kwargs: {"enable_thinking": false}` on a preset
   started with `--reasoning on`, for each template family: Qwen3.5/3.6 and its finetunes, Gemma 4, GLM-4.7.
   Check the response has or lacks `reasoning_content`.
2. Request-level sampling overrides the preset's: send `temperature: 1.0` to a preset with `temp = 0.6` and
   confirm via `GET /slots?model=<head>` (the slot's `params`).
3. Exclude families where reasoning is not a toggle: gpt-oss (`-think-low/medium/high` differ in reasoning
   effort, not on/off), lfm and mellum (always reasoning). Leave them out of `families.json` so they keep
   today's behaviour.

**Side effects to accept or handle:**
- The response's `model` field will say the head's name. Check opencode and afghanica do not compare it.
  If one does, rewrite it back in a body filter.
- `/v1/models` still lists every preset. No change needed.
- `availability.lua` reports the head as the resident model. Bots that compare the resident model with
  their own (afghanica's gate) need to resolve their model through the same map, or they will see a
  "different model" and wait. Check `afghanica` for that comparison before deploying.

**Tests:** extend `tools/test_coordinator.py` and `tools/coord_mock.py` with a scenario: request a sibling
after its head, and assert no unload, a rewritten `model`, and the merged parameters.

---

## Option 3: Keep the models used most on the NVMe drive

**Goal:** cold loads of the models used most read at NVMe speed (several GB/s) instead of 100–500 MB/s.
They are not held in RAM.

**Constraint:** llama.cpp's `-hf` loader uses one HF cache (`/root/.cache/huggingface` in the container,
`.local/llama-cpp_data` on the host, 308 GB). The root filesystem (NVMe) has ~340 GB free, too little to
move the whole cache safely.

**Design: move individual blobs and leave a symlink.** HF snapshots already hold symlinks into `blobs/`.
Move a chosen blob to the NVMe and replace it with a symlink whose target path is **identical on the host
and in the containers**, so it resolves in both:
1. Create `/opt/model-nvme/blobs/` on the root filesystem.
2. Mount it into `llama-cpp` and `prism-llama-cpp` at the **same path**:
   `- /opt/model-nvme:/opt/model-nvme:ro` in `compose.override.yml` (machine-local; it already holds the
   cache mounts).
3. For each chosen model: copy the blob to `/opt/model-nvme/blobs/<sha256>`, check the sha256 matches the
   file name, then atomically replace the blob in the cache with a symlink to it
   (`ln -s … blob.tmp && mv -T blob.tmp blob`).
4. Write `tools/nvme_models.sh` with `move <model>`, `restore <model>` (copy back, replace the symlink) and
   `list`, so this is repeatable and reversible. The model's other files (MTP drafter, mmproj) can stay on
   the RAID.

**Before you start:**
- Ask the user which models to move. Candidates from current use: gemma-4-12b (6.7 GB), tiel-coder q4
  (~22 GB), tiel-coder APEX (~15 GB), lfm-2.5-8b (~5 GB), GLM-4.7-Flash (17.5 GB).
- Confirm free space on `/` leaves a comfortable margin (keep at least 100 GB free).
- Do it with the model unloaded. A loaded model keeps reading the old inode until it unloads, which is
  harmless.

**Risks:**
- **Re-downloads:** the HF downloader verifies blobs by name and size. Check that a restart plus load does
  not re-download or replace the symlink (watch for `*.downloadInProgress` in the repo's dir).
- **Backups:** if `/mnt/md2` is backed up, the blob now lives on `/`. Make sure that is acceptable.
- **No mirror:** the NVMe copy has no RAID1 redundancy. It is a copy of a public download, so losing it
  means re-downloading.

**Verify:** cold-load times (§1) for each moved model, three runs.

---

## Option 4: Rewrite the models used most on the RAID periodically

**Goal:** bring reads of those models on the P3 back from ~100–120 MB/s to ~270 MB/s until the data
ages again. This is a mitigation. It does not fix the drive.

**Design:** a timer that rewrites chosen blobs in place by copy-and-rename, which forces new extents on both
mirrors:
1. `cp --reflink=never <blob> <blob>.refresh`, then `sync`, check sha256 matches, then `mv -T <blob>.refresh <blob>`.
2. Use copy-and-rename, not `btrfs filesystem defragment`, which skips extents that are already contiguous
   and so may rewrite nothing.
3. Writes go to both drives at the BX500's write speed (~25–55 MiB/s sustained): about 6–12 min per
   17.5 GB model. Run it at night, one model at a time, and only while the model is not loading
   (a loaded model keeps the old inode, so a swap underneath it is safe).
4. `tools/refresh_models.sh <model…>` plus a systemd timer (monthly). Data drops to its slow state within
   about 6 weeks (Qwen3-Coder, written Sep 10, already read at the same speed as GLM from Aug 31).

**Before you start:** ask which models. If Option 3 moves a model to the NVMe, it no longer needs this.

**Verify:** the O_DIRECT per-mirror read test (§0) on a refreshed blob, right after the refresh and again
a month later. The test script used on 2026-10-21 maps a file's extents to each mirror with `filefrag` and
`btrfs-map-logical`, then reads both raw partitions. It is read-only. Add it as `tools/mirror_read_test.py`.

**Wear:** each refresh writes the model once to each drive. Monthly refreshes of ~60 GB add ~0.7 TB/year per
drive, small against a 4 TB QLC drive's rated endurance. Check the actual rating before scheduling more often.

---

## Option 5: Read only from the fast drive (btrfs read policy)

**Goal:** every cold read is served by the BX500 (~520 MB/s), whatever the data's age.

**Constraint:** btrfs read policies other than `pid` (`round-robin`, `devid:<n>`) exist only in kernels
built with `CONFIG_BTRFS_EXPERIMENTAL`. This kernel (`7.1.8-arch1-3`) is not:
`/sys/fs/btrfs/<uuid>/read_policy` offers only `[pid]`.

**What it would take:**
1. A kernel built with `CONFIG_BTRFS_EXPERIMENTAL=y`: a custom Arch kernel package, or a distro kernel
   that enables it. Check `zcat /proc/config.gz | grep BTRFS_EXPERIMENTAL` on any candidate.
2. At boot, `echo devid:2 > /sys/fs/btrfs/9a477401-e422-4566-85a5-5a8306ff3572/read_policy`
   (devid 2 is `/dev/sdb1`, the BX500), through a systemd unit.
3. Writes still go to both drives, so redundancy is unchanged. If the BX500 fails, switch the policy back
   to `pid` (or btrfs falls back to the remaining mirror).

**Recommendation:** last resort. A custom kernel is ongoing maintenance on every update, and "experimental"
is the kernel's own label. Consider it only if Options 1–3 are not enough. Do not start without the user's
explicit go-ahead.

---

## Suggested order

| Order | Option | Changes | Needs |
|---|---|---|---|
| 1 | Option 1, mmap + mlock | cortex `[*]` | a quiet bench window |
| 2 | Option 3, models on NVMe | `compose.override.yml`, new tool | the user's list of models |
| 3 | Option 2, one instance per family | openresty, new generator, tests | the §Option 2 checks to pass |
| 4 | Option 4, refresh timer | new tool + timer | only for models not moved to NVMe |
| 5 | Option 5, read policy | kernel | the user's explicit decision |

Options 1 and 3 together cover most of the gain: warm reloads become near-instant, and cold loads of the
models used most come from the NVMe. Option 2 removes loads rather than speeding them up, so its value
depends on how often clients move between variants. Count sibling-to-sibling switches in the openresty log
(`switch: llama_cpp -> llama_cpp (A -> B)` where A and B share a family) over a few days before building it.
