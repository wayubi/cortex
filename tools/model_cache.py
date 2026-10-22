#!/usr/bin/env python3
"""model-cache: keep an NVMe copy of the GGUF files cortex loads most.

Runs as the `model-cache` service (compose.yml). Every POLL seconds it asks
both llama.cpp routers which presets are loaded; a preset that turned
`loaded` since the last poll is one load of the files its `--hf-repo` names.
A file set (the model's GGUF, plus its MTP drafter and, for a preset that
loads one, its mmproj) loaded LOADS times within DAYS days is copied to DIR
and served from there by repointing its HF snapshot link:

    snapshots/<rev>/<name>.gguf -> DIR/<sha256>        (promoted)
    snapshots/<rev>/<name>.gguf -> ../../blobs/<sha256> (as downloaded)

The blob on the SSD is never touched, so the SSD keeps a complete copy and
evicting is only repointing the link and deleting the NVMe file. The router
starts a new llama-server per load, which resolves the link then, so nothing
restarts; a loaded model keeps the file it opened. Copies stay under GB
gigabytes, evicting the least recently loaded first. DIR is mounted at the
same path in both routers, so the absolute link resolves there too.

CORTEX_NVME_CACHE=off points every link back at its blob, deletes the
copies and the state, and exits 0 (restart: on-failure keeps it stopped).
"""
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.request

ENABLED = os.environ.get("CORTEX_NVME_CACHE", "on").strip().lower() not in ("off", "0", "false", "no")
CAP = int(float(os.environ.get("CORTEX_NVME_CACHE_GB", "64")) * 1e9)
LOADS = int(os.environ.get("CORTEX_NVME_CACHE_LOADS", "3"))
WINDOW = float(os.environ.get("CORTEX_NVME_CACHE_DAYS", "7")) * 86400
DIR = os.environ.get("CORTEX_NVME_CACHE_DIR", "/opt/cortex-models").rstrip("/")
HUB = os.environ.get("HF_HUB", "/root/.cache/huggingface/hub")
ROUTERS = [u for u in os.environ.get(
    "CORTEX_ROUTERS",
    "http://llama-cpp:8080,http://prism-llama-cpp:8080,http://flint-llama-cpp:8080").split(",") if u]
POLL = 5
RECONCILE_EVERY = 3600
KEEP_FREE = 50e9           # never let a copy leave less than this free on DIR's filesystem
STATE = os.path.join(DIR, "state.json")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


# ── HF cache layout ─────────────────────────────────────────

def repo_dir(repo):
    return os.path.join(HUB, "models--" + repo.replace("/", "--"))


def snapshot_dir(repo):
    try:
        rev = open(os.path.join(repo_dir(repo), "refs", "main")).read().strip()
    except OSError:
        return None
    d = os.path.join(repo_dir(repo), "snapshots", rev)
    return d if os.path.isdir(d) else None


def blob_of(link):
    """The sha256 a snapshot link stands for, whichever copy it points at."""
    sha = os.path.basename(os.readlink(link))
    return sha if SHA_RE.match(sha) else None


def resolve_files(hf, with_mmproj):
    """Snapshot links (relative to HUB) of the files a preset `hf = repo[:quant]` loads.
    The main GGUF, its MTP drafter, and its mmproj only if the preset loads one.
    None when the choice is ambiguous (an untagged repo with several models)."""
    repo, _, quant = hf.partition(":")
    snap = snapshot_dir(repo)
    if not snap:
        return None
    names = sorted(n for n in os.listdir(snap) if n.lower().endswith(".gguf")
                   and os.path.islink(os.path.join(snap, n)))
    mtp = [n for n in names if n.lower().startswith("mtp-")]
    proj = [n for n in names if "mmproj" in n.lower()]
    rest = [n for n in names if n not in mtp and n not in proj]
    if quant:
        q = quant.lower()
        main = [n for n in rest if n.lower().endswith((f"-{q}.gguf", f".{q}.gguf"))]
        if not main:
            main = [n for n in rest if re.search(rf"[-.]{re.escape(q)}-\d{{5}}-of-\d{{5}}\.gguf$", n.lower())]
    else:
        main = rest if len(rest) == 1 else []
    if not main:
        return None
    files = main + mtp + (proj if with_mmproj else [])
    return [os.path.relpath(os.path.join(snap, n), HUB) for n in files]


# ── state ───────────────────────────────────────────────────
# state["sets"][key]: {"files": [{"link", "sha", "size"}], "loads": [ts], "last": ts,
#                     "promoted": bool, "hf": str}; key = the main file's sha256.

def load_state():
    try:
        with open(STATE) as f:
            s = json.load(f)
        if isinstance(s.get("sets"), dict):
            return s
    except (OSError, ValueError):
        pass
    return {"sets": {}}


def save_state(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


# ── links ───────────────────────────────────────────────────

def point(link_rel, target):
    link = os.path.join(HUB, link_rel)
    tmp = link + ".model-cache-tmp"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, link)


def to_blob(link_rel, sha):
    point(link_rel, f"../../blobs/{sha}")


def to_copy(link_rel, sha):
    point(link_rel, f"{DIR}/{sha}")


def copy_path(sha):
    return os.path.join(DIR, sha)


def all_links_into_dir():
    """Every snapshot link in the HF cache that points into DIR: (link_rel, sha)."""
    out = []
    for rd in os.listdir(HUB):
        snaps = os.path.join(HUB, rd, "snapshots")
        if not os.path.isdir(snaps):
            continue
        for rev in os.listdir(snaps):
            sd = os.path.join(snaps, rev)
            for n in os.listdir(sd):
                p = os.path.join(sd, n)
                if os.path.islink(p) and os.readlink(p).startswith(DIR + "/"):
                    out.append((os.path.relpath(p, HUB), os.path.basename(os.readlink(p))))
    return out


# ── promote / evict ─────────────────────────────────────────

def used_bytes(state):
    return sum(f["size"] for s in state["sets"].values() if s.get("promoted") for f in s["files"])


def evict(state, key, why):
    s = state["sets"][key]
    for f in s["files"]:
        if os.path.islink(os.path.join(HUB, f["link"])):
            to_blob(f["link"], f["sha"])
    shared = {f["sha"] for k, o in state["sets"].items() if k != key and o.get("promoted") for f in o["files"]}
    for f in s["files"]:
        if f["sha"] not in shared:
            try:
                os.unlink(copy_path(f["sha"]))
            except FileNotFoundError:
                pass
    s["promoted"] = False
    log(f"evicted {s['hf']} ({why})")


def copy_verified(sha, size):
    """Copy blob `sha` to DIR, hashing as it goes; True when the copy matches its name."""
    src = blob_path(sha)
    if not src:
        return False
    dst = copy_path(sha)
    part = dst + ".part"
    h = hashlib.sha256()
    with open(src, "rb") as fi, open(part, "wb") as fo:
        while True:
            b = fi.read(16 << 20)
            if not b:
                break
            h.update(b)
            fo.write(b)
        fo.flush()
        os.fsync(fo.fileno())
    if h.hexdigest() != sha or os.path.getsize(part) != size:
        os.unlink(part)
        log(f"copy of {sha[:12]} does not match its sha256; not promoted")
        return False
    os.replace(part, dst)
    return True


BLOBS = {}   # sha -> blob path, filled on demand


def blob_path(sha):
    p = BLOBS.get(sha)
    if p and os.path.exists(p):
        return p
    for rd in os.listdir(HUB):
        cand = os.path.join(HUB, rd, "blobs", sha)
        if os.path.isfile(cand) and not os.path.islink(cand):
            BLOBS[sha] = cand
            return cand
    return None


def promote(state, key):
    s = state["sets"][key]
    need = sum(f["size"] for f in s["files"] if not os.path.exists(copy_path(f["sha"])))
    if need > CAP:
        log(f"{s['hf']}: {need / 1e9:.1f} GB is larger than the {CAP / 1e9:.0f} GB cap; not copied")
        return
    while used_bytes(state) + need > CAP:
        victims = [(o["last"], k) for k, o in state["sets"].items() if o.get("promoted") and k != key]
        if not victims:
            break
        evict(state, min(victims)[1], "least recently loaded, to make room")
    if shutil.disk_usage(DIR).free - need < KEEP_FREE:
        log(f"{s['hf']}: not enough free space on {DIR}; not copied")
        return
    t0 = time.time()
    for f in s["files"]:
        if not os.path.exists(copy_path(f["sha"])) and not copy_verified(f["sha"], f["size"]):
            return
    for f in s["files"]:
        to_copy(f["link"], f["sha"])
    s["promoted"] = True
    log(f"promoted {s['hf']} ({need / 1e9:.1f} GB in {time.time() - t0:.0f}s; "
        f"{used_bytes(state) / 1e9:.1f} of {CAP / 1e9:.0f} GB used)")


# ── reconcile ───────────────────────────────────────────────

def reconcile(state):
    """Repair anything a crash, a deleted copy or a new model revision left behind."""
    wanted = {}
    for key, s in list(state["sets"].items()):
        if not s.get("promoted"):
            continue
        ok = True
        for f in s["files"]:
            link = os.path.join(HUB, f["link"])
            c = copy_path(f["sha"])
            if not os.path.islink(link) or not os.path.exists(c) or os.path.getsize(c) != f["size"]:
                ok = False
        current = snapshot_dir(s["hf"].partition(":")[0])
        if current and not all(os.path.join(HUB, f["link"]).startswith(current + "/") for f in s["files"]):
            ok = False   # a newer revision was downloaded; this copy is stale
        if ok:
            wanted.update({f["sha"]: True for f in s["files"]})
        else:
            for f in s["files"]:
                if os.path.islink(os.path.join(HUB, f["link"])):
                    to_blob(f["link"], f["sha"])
            s["promoted"] = False
            log(f"reconcile: {s['hf']} no longer served from {DIR}")
    # a link into DIR that the state does not know (state lost): back to its blob
    for link_rel, sha in all_links_into_dir():
        if sha not in wanted:
            to_blob(link_rel, sha)
            log(f"reconcile: {link_rel} pointed back at its blob")
    # files in DIR that no promoted set uses
    for n in os.listdir(DIR):
        p = os.path.join(DIR, n)
        if n.endswith(".part") or (SHA_RE.match(n) and n not in wanted):
            os.unlink(p)
            log(f"reconcile: removed {n[:16]}")


def disable():
    n = 0
    for link_rel, sha in all_links_into_dir():
        to_blob(link_rel, sha)
        n += 1
    for name in os.listdir(DIR):
        if SHA_RE.match(name) or name.endswith(".part") or name.startswith("state.json"):
            os.unlink(os.path.join(DIR, name))
    log(f"CORTEX_NVME_CACHE=off: {n} links pointed back at the SSD blobs, copies removed; exiting")


# ── loads ───────────────────────────────────────────────────

def loaded_presets(url):
    """{preset: args} of the presets this router reports loaded; None if it did not answer."""
    try:
        with urllib.request.urlopen(url + "/v1/models", timeout=5) as r:
            data = json.load(r).get("data", [])
    except Exception:
        return None
    return {m["id"]: (m.get("status") or {}).get("args") or [] for m in data
            if (m.get("status") or {}).get("value") == "loaded"}


def arg(args, name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def on_load(state, preset, args):
    hf = arg(args, "--hf-repo")
    if not hf:
        return
    files = resolve_files(hf, with_mmproj="--no-mmproj-auto" not in args)
    if not files:
        log(f"load of {preset}: cannot tell which files {hf} uses; not tracked")
        return
    entries = []
    for link_rel in files:
        sha = blob_of(os.path.join(HUB, link_rel))
        bp = blob_path(sha) if sha else None
        if not bp:
            return
        entries.append({"link": link_rel, "sha": sha, "size": os.path.getsize(bp)})
    key = entries[0]["sha"]
    now = time.time()
    s = state["sets"].setdefault(key, {"hf": hf, "loads": [], "promoted": False})
    s["files"], s["hf"], s["last"] = entries, hf, now
    s["loads"] = [t for t in s["loads"] if now - t < WINDOW] + [now]
    where = "NVMe" if s["promoted"] else f"SSD, load {len(s['loads'])}/{LOADS}"
    log(f"load: {preset} ({hf}; {where})")
    if not s["promoted"] and len(s["loads"]) >= LOADS:
        promote(state, key)


def main():
    os.makedirs(DIR, exist_ok=True)
    if not ENABLED:
        disable()
        return 0
    log(f"on: copy a model to {DIR} at load #{LOADS} within {WINDOW / 86400:g} days, "
        f"cap {CAP / 1e9:g} GB; routers {', '.join(ROUTERS)}")
    state = load_state()
    reconcile(state)
    save_state(state)
    seen = {u: None for u in ROUTERS}
    last_reconcile = time.time()
    while True:
        changed = False
        for url in ROUTERS:
            now_loaded = loaded_presets(url)
            if now_loaded is None:
                continue                      # router down or restarting: keep what we knew
            if seen[url] is not None:
                for preset, args in now_loaded.items():
                    if preset not in seen[url]:
                        try:
                            on_load(state, preset, args)
                            changed = True
                        except Exception as e:
                            log(f"load of {preset}: {type(e).__name__}: {e}")
            seen[url] = now_loaded
        if time.time() - last_reconcile > RECONCILE_EVERY:
            reconcile(state)
            last_reconcile = time.time()
            changed = True
        if changed:
            save_state(state)
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
