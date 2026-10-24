#!/usr/bin/env python3
"""Offline test of openresty's coordinator: human priority, the bot hold.

    python3 tools/test_coordinator.py            # the working tree
    python3 tools/test_coordinator.py --ref HEAD # a commit, to show what fails

Starts a private docker network with tools/coord_mock.py standing in for all
the backends (more mocks play prism-, flint- and raon-llama-cpp, the
routers that share :8080 with llama-cpp) and a throwaway openresty running the
real nginx.conf and Lua from openresty/. Nothing touches the live stack or the GPU. cortex.lua's
HUMAN_HOLD and BOT_HOLD_CAP are shortened to HOLD and CAP below so a run takes
about a minute; every other line is the shipped code.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = "openresty/openresty:bookworm-fat"
MOCK_IMAGE = "python:3.11-slim"
HOLD = 3
CAP = 6
LUA = ("coordinator.lua", "availability.lua", "cortex.lua", "log.lua", "models_list.lua")
# :8080 models that route to prism- / flint- / raon-llama-cpp (their
# models.ini section names); every other :8080 model goes to llama-cpp
PRISM_MODELS = ("m-prism", "m-prism2")
FLINT_MODELS = ("m-flint", "m-flint2")
RAON_MODELS = ("m-raon",)
# the extra :8080 routers: (suffix, host, backend key, its models)
EXTRA = (("pmock", "prism-llama-cpp", "prism_llama_cpp", PRISM_MODELS),
         ("fmock", "flint-llama-cpp", "flint_llama_cpp", FLINT_MODELS),
         ("rmock", "raon-llama-cpp", "raon_llama_cpp", RAON_MODELS))


def router_of(model):
    """The backend key that should serve a :8080 model."""
    for _, _, key, models in EXTRA:
        if model in models:
            return key
    return "llama_cpp"


def sh(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True).stdout.strip()


def stage(ref, out):
    """Copy openresty/ at `ref` (None: the working tree) into `out`."""
    os.makedirs(out, exist_ok=True)
    for f in ("nginx.conf",) + LUA:
        if ref is None:
            src = os.path.join(ROOT, "openresty", f)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(out, f))
        else:
            r = subprocess.run(["git", "-C", ROOT, "show", f"{ref}:openresty/{f}"],
                               capture_output=True, text=True)
            if r.returncode == 0:
                with open(os.path.join(out, f), "w") as fh:
                    fh.write(r.stdout)
    pol = os.path.join(out, "cortex.lua")
    if os.path.exists(pol):
        s = open(pol).read()
        s = re.sub(r"M\.HUMAN_HOLD = \d+", f"M.HUMAN_HOLD = {HOLD}", s)
        s = re.sub(r"M\.BOT_HOLD_CAP = \d+", f"M.BOT_HOLD_CAP = {CAP}", s)
        open(pol, "w").write(s)
    for _, host, _, models in EXTRA:
        with open(os.path.join(out, host.split("-")[0] + "-models.ini"), "w") as fh:
            fh.write("[*]\nctx-size = 4096\n\n" + "".join(f"[{m}]\nhf = x/y\n\n" for m in models))


class Stack:
    def __init__(self, conf_dir):
        self.name = f"cortex-coordtest-{os.getpid()}"
        sh("docker", "network", "create", self.name)
        sh("docker", "run", "-d", "--name", self.name + "-mock", "--network", self.name,
           "--network-alias", "llama-cpp", "--network-alias", "ollama",
           "--network-alias", "nllb",
           "-v", os.path.join(ROOT, "tools", "coord_mock.py") + ":/m.py:ro",
           MOCK_IMAGE, "python", "-u", "/m.py")
        vols = ["-v", os.path.join(conf_dir, "nginx.conf") + ":/etc/nginx/conf.d/default.conf:ro"]
        for suffix, host, key, _ in EXTRA:
            sh("docker", "run", "-d", "--name", self.name + "-" + suffix, "--network", self.name,
               "--network-alias", host, "-e", "MOCK_8080=" + key,
               "-v", os.path.join(ROOT, "tools", "coord_mock.py") + ":/m.py:ro",
               MOCK_IMAGE, "python", "-u", "/m.py")
            ini = host.split("-")[0] + "-models.ini"
            vols += ["-v", os.path.join(conf_dir, ini) + ":/etc/nginx/" + ini + ":ro"]
        for f in LUA:
            p = os.path.join(conf_dir, f)
            if os.path.exists(p):
                vols += ["-v", f"{p}:/etc/nginx/lua/{f}:ro"]
        sh("docker", "run", "-d", "--name", self.name + "-or", "--network", self.name,
           "-p", "127.0.0.1::8080", "-p", "127.0.0.1::11434", "-p", "127.0.0.1::5002",
           *vols, IMAGE)
        self.wait_up()

    def restart_openresty(self):
        """Fresh shared dicts while the mocks keep what they hold -- what a
        real openresty restart looks like to the coordinator."""
        sh("docker", "restart", self.name + "-or")
        self.wait_up()

    def wait_up(self):
        self.port = {}
        for p in (8080, 11434, 5002):
            self.port[p] = int(sh("docker", "port", self.name + "-or", str(p)).split(":")[-1])
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                self.get(8080, "/v1/models")
                return
            except Exception:
                time.sleep(0.3)
        raise RuntimeError("openresty did not come up:\n" + self.logs())

    def url(self, port, path):
        return f"http://127.0.0.1:{self.port[port]}{path}"

    def get(self, port, path):
        with urllib.request.urlopen(self.url(port, path), timeout=5) as r:
            return json.loads(r.read())

    def logs(self):
        return sh("docker", "logs", self.name + "-or", check=False) + \
            subprocess.run(["docker", "logs", self.name + "-or"], capture_output=True,
                           text=True).stderr

    def close(self):
        for c in ("-or", "-mock") + tuple("-" + e[0] for e in EXTRA):
            subprocess.run(["docker", "rm", "-f", self.name + c], capture_output=True)
        subprocess.run(["docker", "network", "rm", self.name], capture_output=True)


class Call(threading.Thread):
    """One POST on its own thread, timed from the shared t0."""

    def __init__(self, stack, t0, port, model, delay, bot, after=0.0, timeout=30):
        super().__init__(daemon=True)
        self.args = (stack, t0, port, model, delay, bot, after, timeout)
        self.status = self.held = self.end = self.body = None

    def run(self):
        stack, t0, port, model, delay, bot, after, timeout = self.args
        time.sleep(after)
        path = "/api/generate" if port == 11434 else "/v1/chat/completions"
        req = urllib.request.Request(
            stack.url(port, path), method="POST",
            data=json.dumps({"model": model, "delay": delay}).encode(),
            headers={"Content-Type": "application/json",
                     **({"X-Cortex-Client": "bot"} if bot else {})})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                self.status = r.status
                self.body = json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            self.status, self.held = e.code, e.headers.get("X-Cortex-Held")
        except Exception as e:                    # client-side timeout: an abort
            self.status = f"abort ({type(e).__name__})"
        self.end = time.time() - t0


def settle(stack):
    """Wait out the human hold and require nothing left counted."""
    time.sleep(HOLD + 1)
    a = stack.get(8080, "/availability")
    leaks = {k: v for k, v in a["in_flight"].items() if v}
    assert not leaks, f"in-flight counts leaked: {a}"
    assert not a.get("human_pending"), f"human_pending leaked: {a}"


FAILS = []


def check(name, cond, detail):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f": {detail}"))
    if not cond:
        FAILS.append(name)


def scenario_human_waits_only_for_the_call_in_flight(stack):
    """A bot call is running; a human arrives; the bot's next call, for the
    resident model, must not cut in front of the human -- and must then stay
    out until the human has been quiet HOLD seconds."""
    print("human waits only for the bot call in flight")
    t0 = time.time()
    b1 = Call(stack, t0, 8080, "m-bot", 2.0, bot=True)
    h = Call(stack, t0, 11434, "m-human", 0.2, bot=False, after=0.3)
    b2 = Call(stack, t0, 8080, "m-bot", 0.1, bot=True, after=0.6)
    for c in (b1, h, b2):
        c.start()
    for c in (b1, h, b2):
        c.join()
    check("the bot call in flight is not interrupted", b1.status == 200, b1.status)
    check("the human is served right after it", h.status == 200 and h.end < 2.0 + 1.5,
          (h.status, h.end))
    check("the bot's next call waits for the human", b2.end > h.end, (b2.end, h.end))
    check("and stays out for the hold window", b2.status == 200 and b2.end >= h.end + HOLD - 0.5,
          (b2.status, b2.end, h.end))
    settle(stack)


def scenario_bot_sharing_the_human_model_is_not_held(stack):
    print("a bot sharing the human's model goes straight through; one that would evict it waits")
    t0 = time.time()
    h = Call(stack, t0, 11434, "m-human", 0.2, bot=False)
    same = Call(stack, t0, 11434, "m-human", 0.1, bot=True, after=0.6)
    other = Call(stack, t0, 8080, "m-bot", 0.1, bot=True, after=0.7)
    for c in (h, same, other):
        c.start()
    for c in (h, same, other):
        c.join()
    check("same-model bot not held", same.status == 200 and same.end < 1.5, (same.status, same.end))
    check("evicting bot held for the window", other.status == 200 and other.end >= h.end + HOLD - 0.5,
          (other.status, other.end, h.end))
    settle(stack)


def scenario_hold_cap_answers_503(stack):
    print("a bot held past the cap gets 503 X-Cortex-Held: human")
    t0 = time.time()
    humans = [Call(stack, t0, 11434, "m-human", 0.1, bot=False, after=i * 1.0)
              for i in range(CAP + 3)]
    bot = Call(stack, t0, 8080, "m-bot", 0.1, bot=True, after=0.5)
    for c in humans + [bot]:
        c.start()
    for c in humans + [bot]:
        c.join()
    check("503 with the held marker", bot.status == 503 and bot.held == "human",
          (bot.status, bot.held))
    check("after the cap, not before", bot.end is not None and CAP - 0.5 <= bot.end - 0.5 <= CAP + 2,
          bot.end)
    settle(stack)


def scenario_availability_reports_the_human(stack):
    print("/availability reports human_pending and human_idle_for")
    t0 = time.time()
    h = Call(stack, t0, 11434, "m-human", 1.5, bot=False)
    h.start()
    time.sleep(0.6)
    during = stack.get(5002, "/availability")
    h.join()
    time.sleep(1.0)
    after = stack.get(8080, "/availability")
    check("pending while it runs", during.get("human_pending") is True and during.get("human_idle_for") == 0,
          during)
    check("idle_for counts after it ends", after.get("human_pending") is False
          and isinstance(after.get("human_idle_for"), (int, float)) and after["human_idle_for"] >= 0.5,
          after)
    settle(stack)


def scenario_aborts_release_everything(stack):
    print("a client that hangs up while held or draining leaves nothing counted")
    t0 = time.time()
    b = Call(stack, t0, 8080, "m-bot", 2.5, bot=True)
    h = Call(stack, t0, 11434, "m-human", 0.1, bot=False, after=0.3, timeout=1.0)   # aborts in drain
    for c in (b, h):
        c.start()
    for c in (b, h):
        c.join()
    a = stack.get(8080, "/availability")
    check("human aborted mid-drain is not still pending", str(h.status).startswith("abort")
          and a.get("human_pending") is False, (h.status, a))
    # it held the switch key while it drained; a leaked key would park every
    # later switch for the key's TTL (~700s)
    nxt = Call(stack, time.time(), 8080, "m-x", 0.1, bot=False, timeout=5)
    nxt.start(); nxt.join()
    check("the switch key it held is released", nxt.status == 200, nxt.status)
    # a human request now sets the hold; a bot gives up while held
    t0 = time.time()
    h2 = Call(stack, t0, 11434, "m-human", 0.1, bot=False)
    held = Call(stack, t0, 8080, "m-bot", 0.1, bot=True, after=0.4, timeout=1.0)
    for c in (h2, held):
        c.start()
    for c in (h2, held):
        c.join()
    check("held bot that hung up is not counted", str(held.status).startswith("abort")
          and not any(stack.get(8080, "/availability")["in_flight"].values()),
          (held.status, stack.get(8080, "/availability")))
    settle(stack)


def scenario_concurrent_switches_do_not_deadlock(stack):
    """opencode sends requests for different models on one backend at once.
    Each counted itself in flight before draining and waited for the count to
    fall to itself -- so two waiters waited on each other until a client gave
    up (cortex logs 2026-10-01 23:49: "drain llama_cpp (3 active, target 1)")."""
    print("concurrent requests for different models on one backend all complete")
    t0 = time.time()
    seed = Call(stack, t0, 8080, "m-a", 0.1, bot=False)
    seed.start(); seed.join()
    t0 = time.time()
    calls = [Call(stack, t0, 8080, m, 0.3, bot=False, timeout=15)
             for m in ("m-b", "m-c", "m-b", "m-d")]
    for c in calls:
        c.start()
    for c in calls:
        c.join()
    check("every request served", all(c.status == 200 for c in calls),
          [(c.status, c.end) for c in calls])
    check("promptly", all(c.end is not None and c.end < 8 for c in calls),
          [c.end for c in calls])
    a = stack.get(8080, "/availability")
    check("nothing left counted", not any(a["in_flight"].values()) and not a.get("human_pending"), a)
    settle(stack)


def loaded_on_8080(stack):
    """{model: backend} for every model a router reports loaded, read through
    the merged GET /v1/models (the mocks list only their loaded model)."""
    out = {}
    for e in stack.get(8080, "/v1/models").get("data", []):
        if (e.get("status") or {}).get("value") == "loaded":
            out[e["id"]] = router_of(e["id"])
    return out


def scenario_prism_routes_by_model_and_switches(stack):
    """:8080 serves two llama.cpp routers; the model name picks one, and moving
    between them unloads the other, like any backend switch."""
    print("a prism model on :8080 goes to prism-llama-cpp; switching unloads the other router")
    t0 = time.time()
    a = Call(stack, t0, 8080, "m-a", 0.1, bot=False)
    a.start(); a.join()
    check("a llama model is served by llama-cpp", a.status == 200
          and (a.body or {}).get("backend") == "llama_cpp", (a.status, a.body))
    p = Call(stack, time.time(), 8080, "m-prism", 0.1, bot=False)
    p.start(); p.join()
    check("a prism model is served by prism-llama-cpp", p.status == 200
          and (p.body or {}).get("backend") == "prism_llama_cpp", (p.status, p.body))
    check("and llama-cpp was unloaded first", loaded_on_8080(stack) == {"m-prism": "prism_llama_cpp"},
          loaded_on_8080(stack))
    av = stack.get(8080, "/availability")
    check("availability names the prism backend", av.get("backend") == "prism_llama_cpp"
          and "prism_llama_cpp" in av.get("in_flight", {}), av)
    b = Call(stack, time.time(), 8080, "m-a", 0.1, bot=False)
    b.start(); b.join()
    check("back to llama-cpp unloads prism-llama-cpp", b.status == 200
          and loaded_on_8080(stack) == {"m-a": "llama_cpp"}, (b.status, loaded_on_8080(stack)))
    props = stack.get(8080, "/props?model=m-prism")
    check("a GET naming a prism model reaches prism-llama-cpp",
          props.get("backend") == "prism_llama_cpp", props)
    check("a GET naming no model reaches llama-cpp",
          stack.get(8080, "/props").get("backend") == "llama_cpp", stack.get(8080, "/props"))
    settle(stack)


def scenario_flint_routes_by_model_and_switches(stack):
    """A third :8080 router, flint-llama-cpp, routes and switches like prism."""
    print("a Flint model on :8080 goes to flint-llama-cpp; switching unloads the router it leaves")
    p = Call(stack, time.time(), 8080, "m-prism", 0.1, bot=False)
    p.start(); p.join()
    e = Call(stack, time.time(), 8080, "m-flint", 0.1, bot=False)
    e.start(); e.join()
    check("a Flint model is served by flint-llama-cpp", e.status == 200
          and (e.body or {}).get("backend") == "flint_llama_cpp", (e.status, e.body))
    check("and prism-llama-cpp was unloaded first", loaded_on_8080(stack) == {"m-flint": "flint_llama_cpp"},
          loaded_on_8080(stack))
    av = stack.get(8080, "/availability")
    check("availability names the flint backend", av.get("backend") == "flint_llama_cpp"
          and "flint_llama_cpp" in av.get("in_flight", {}), av)
    check("a GET naming a Flint model reaches flint-llama-cpp",
          stack.get(8080, "/props?model=m-flint").get("backend") == "flint_llama_cpp",
          stack.get(8080, "/props?model=m-flint"))
    a = Call(stack, time.time(), 8080, "m-a", 0.1, bot=False)
    a.start(); a.join()
    check("back to llama-cpp unloads flint-llama-cpp", a.status == 200
          and loaded_on_8080(stack) == {"m-a": "llama_cpp"}, (a.status, loaded_on_8080(stack)))
    settle(stack)


def scenario_raon_routes_and_switches_from_another_extra_router(stack):
    """A fourth router, raon-llama-cpp: moving between two non-default routers
    unloads the one left behind."""
    print("a Raon model goes to raon-llama-cpp; leaving flint-llama-cpp for it unloads flint")
    f = Call(stack, time.time(), 8080, "m-flint", 0.1, bot=False)
    f.start(); f.join()
    r = Call(stack, time.time(), 8080, "m-raon", 0.1, bot=False)
    r.start(); r.join()
    check("a Raon model is served by raon-llama-cpp", r.status == 200
          and (r.body or {}).get("backend") == "raon_llama_cpp", (r.status, r.body))
    check("and flint-llama-cpp was unloaded first", loaded_on_8080(stack) == {"m-raon": "raon_llama_cpp"},
          loaded_on_8080(stack))
    a = Call(stack, time.time(), 8080, "m-a", 0.1, bot=False)
    a.start(); a.join()
    check("back to llama-cpp unloads raon-llama-cpp", a.status == 200
          and loaded_on_8080(stack) == {"m-a": "llama_cpp"}, (a.status, loaded_on_8080(stack)))
    settle(stack)


def scenario_mixed_routers_concurrently(stack):
    print("concurrent requests across all :8080 routers all complete, nothing left counted")
    t0 = time.time()
    calls = [Call(stack, t0, 8080, m, 0.3, bot=False, timeout=20)
             for m in ("m-a", "m-prism", "m-flint", "m-raon", "m-b", "m-prism2", "m-flint2", "m-prism")]
    for c in calls:
        c.start()
    for c in calls:
        c.join()
    check("every request served", all(c.status == 200 for c in calls),
          [(c.status, c.end) for c in calls])
    check("each by its own router", all((c.body or {}).get("backend") ==
          router_of(c.args[3]) for c in calls),
          [(c.args[3], (c.body or {}).get("backend")) for c in calls])
    check("one model resident at the end", len(loaded_on_8080(stack)) == 1, loaded_on_8080(stack))
    settle(stack)


def scenario_fresh_state_unloads_what_is_resident(stack):
    """After an openresty restart the shared dicts are empty while a router
    still holds a model; the first switch must clear it, not load beside it."""
    print("after an openresty restart the first request clears what a backend still holds")
    a = Call(stack, time.time(), 8080, "m-flint", 0.1, bot=False)
    a.start(); a.join()
    stack.restart_openresty()
    check("state is empty after the restart", stack.get(8080, "/availability").get("backend") is None,
          stack.get(8080, "/availability"))
    p = Call(stack, time.time(), 8080, "m-prism", 0.1, bot=False)
    p.start(); p.join()
    check("flint-llama-cpp's leftover model was unloaded", p.status == 200
          and loaded_on_8080(stack) == {"m-prism": "prism_llama_cpp"}, (p.status, loaded_on_8080(stack)))
    settle(stack)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", help="test openresty/ as of this commit instead of the working tree")
    args = ap.parse_args()
    conf = tempfile.mkdtemp(prefix="coordtest-")
    stage(args.ref, conf)
    stack = Stack(conf)
    try:
        for fn in (scenario_human_waits_only_for_the_call_in_flight,
                   scenario_bot_sharing_the_human_model_is_not_held,
                   scenario_hold_cap_answers_503,
                   scenario_availability_reports_the_human,
                   scenario_aborts_release_everything,
                   scenario_concurrent_switches_do_not_deadlock,
                   scenario_prism_routes_by_model_and_switches,
                   scenario_flint_routes_by_model_and_switches,
                   scenario_raon_routes_and_switches_from_another_extra_router,
                   scenario_mixed_routers_concurrently,
                   scenario_fresh_state_unloads_what_is_resident):
            try:
                fn(stack)
            except Exception as e:
                check(fn.__name__, False, f"{type(e).__name__}: {e}")
    finally:
        if FAILS and os.environ.get("COORDTEST_LOGS"):
            print(stack.logs()[-6000:])
        stack.close()
        shutil.rmtree(conf, ignore_errors=True)
    print(f"{len(FAILS)} failed" if FAILS else "all passed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
