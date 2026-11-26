# Handoff: OpenCode agents, commands and skills

**Started:** 2026-11-26
**Last updated:** 2026-11-26
**Status:** In testing. First finding (2026-11-26): calling advisor and reviewer together was
slow; changed to advisor until `PASS`, then reviewer.

This document is maintained across sessions. Update "Last updated", the status, the change log and
the open items whenever any of these files change.

## Goal

- An **orchestrator** primary agent that owns a task end to end: reads the governing documents,
  plans, sends the code writing to a fast **coder** subagent, verifies, and has the **advisor** and
  **reviewer** check the work **automatically** whenever the task is done, without being prompted.
- The orchestrator sends **all subtasks of a stage at once** and waits for the last one, so it does
  not re-prefill its context once per subtask.
- The **advisor** is a critical second opinion that works from first principles: it finds the
  source documents itself, treats the caller's claims as claims, and checks the work against the
  spec. It must need **no project-specific instructions**.
- **Project-agnostic.** The setup is used across many projects; nothing may depend on a project's `AGENTS.md`
  or cater to one project. Everything lives in the global OpenCode config.
- Keep model swaps on the single GPU few: the coordinator unloads the resident model whenever the
  requested model name changes, and the orchestrator re-reads its whole context after each swap.
- qwen (the slowest, CPU-placed) should run least often: only at the end of a task.
- **The primary is expected to make mistakes.** No primary, however strong, is trusted to get a
  task right alone; the advisor and reviewer exist to catch what it misses. The checkers' quality
  therefore matters more than the orchestrator's.

## Where things are

Global OpenCode config in `.local/opencode_data/`, which is machine-local and **not in this
repository** (`.local/` is gitignored), mounted into the `opencode` container at
`/root/.config/opencode`. OpenCode version in the container: **v2.2.5**.

| File | Kind | Model | What |
|---|---|---|---|
| `agents/orchestrator.md` | primary | groot-19b-a3b-iq3m-mtp-128k-think-coder | plans, batches subagents, verifies, then advisor until PASS, then reviewer |
| `agents/coder.md` | subagent | mellum-2.1-12b-a2.5b-q4-128k-think | writes code from a brief; only the named files |
| `agents/scout.md` | subagent | mellum (same entry as coder) | read-only search, answers with `path:line` evidence |
| `agents/vision.md` | subagent | gemma-4-12b-q4-qat-mtp-64k-vision | reads images for the text-only agents |
| `agents/advisor.md` | subagent | qwen-3.6-35b-a3b-q4-mtp-128k-think-coder | checks work/plans against source documents |
| `agents/reviewer.md` | subagent | qwen (same entry as advisor) | reviews the code changes for defects |
| `commands/orchestrate.md` | `/orchestrate <task>` | — | runs the task as `orchestrator` |
| `commands/review.md` | `/review [focus]` | — | `reviewer` as a subagent on uncommitted changes (else branch vs base) |
| `commands/verify.md` | `/verify [doc paths / focus]` | — | `advisor` as a subagent against the source documents |
| `commands/handoff.md` | `/handoff [topic or path]` | — | current agent writes/updates `handoff-<topic>.md` in the project's planning folder (no swap) |
| `skills/chrome-web/SKILL.md` | skill | — | browser skill; independent of the agents |
| `opencode.json` | config | — | providers (generated) + `mcp`; no `plugins` key any more |

### Permissions (what each subagent can do)

| Agent | Read/search files | Edit/write | Shell | Other denied |
|---|---|---|---|---|
| coder | yes | yes | none | subagent, webfetch, external_directory, question |
| scout | yes | no | read-only git: status, log, show, ls-files, grep | subagent, webfetch, question |
| vision | yes | no | none | subagent, webfetch, question |
| advisor | yes | no | read-only git: status, diff, log, show, ls-files, blame | subagent |
| reviewer | yes | no | read-only git: status, diff, log, show, blame, merge-base, ls-files | subagent |
| orchestrator | OpenCode defaults (no permissions block) | | | |

Every agent with git access also denies `;`, `&`, `|`, `>`, `<`, backticks, `$(` and `--output`
(`git diff --output=FILE` writes a file), so the allowed git commands stay read-only.

## Design

### Flow

1. Select `orchestrator` (Tab / agent picker), or runs `/orchestrate <task>`.
2. Orchestrator reads the governing documents (project instructions, spec, work order, issues,
   review rounds) and the code; broad searches go to `scout` batches, images to `vision` (own
   message).
3. It splits the work into **independent** coder tasks, **each file owned by exactly one task**,
   and writes a complete brief per task (Files to change or create / Change / Constraints / Done
   when).
4. It sends **every coder task of a batch in one message** and waits for all of them.
5. It verifies itself: `git diff` plus the new untracked files, runs the tests, checks each
   requirement against the files.
6. When it believes it is done, it checks automatically, **advisor first, reviewer second, never
   together**. It calls the `advisor` alone (document paths, diff, command output, its claims) and
   goes back and forth, fixing findings and sending what it could not verify, until the advisor's
   verdict line is `PASS` (at most three rounds; otherwise it reports the open findings and skips
   the reviewer). Then it calls the `reviewer` alone, fixes Critical/High findings (at most two
   rounds), and re-asks the advisor once if a reviewer fix changes behaviour a requirement covers.
   A finding is resolved by a fix or by evidence that it is wrong.

### Why each choice

- **Batches.** Each delegation unloads groot and loads mellum, then groot reloads and re-reads its
  context (groot bench: ~1,450 t/s prefill, so ~40 s per 60K-token context, plus load time,
  unmeasured). One batch per stage means one wake-up instead of one per task.
- **One model per message.** Mixing models in one message swaps between requests. Groups that may
  share a message: coder + scout (mellum); vision alone (gemma). Advisor and reviewer share a model
  (qwen) but are called one at a time (below). Any two
  differently named models.ini entries swap, even with the same weights, so the sharing agents use
  the identical entry name.
- **Advisor before reviewer, one at a time.** Calling both together was slow in testing (likely
  because they share one slot, so they ran one after the other and evicted each other's prompt;
  cause not measured), and reviewing
  code that does not yet meet the requirements is wasted work. Same model, so moving from advisor to
  reviewer is no swap. The advisor's verdict line is `PASS` / `NOT PASSED` / `CAN'T VERIFY` when it
  checks work, so the orchestrator has an unambiguous signal.
- **Advisor/reviewer only at the end** (orchestrator step 7; never while planning, between batches
  or when stuck): each call is a qwen swap. The advisor's description still says "when choosing an
  approach, or when stuck"; that is left for other primary agents (e.g. the built-in build agent).
- **Coder has minimal tools.** In use, mellum has proved a good coder but poor at agentic tasks,
  so the orchestrator explores, runs and verifies, and the coder only follows a brief. `question`
  is denied because it would block a batch; questions go in its final report.
- **Scout on mellum** so scouts can share a message with coders and cost no extra model.
- **Vision exists** because groot, mellum and qwen are text-only (OpenCode lists only the vision
  entries with image input); it pairs with the chrome-web skill's screenshots.
- **Advisor checks the source of truth first, on every request**, not only in a "verification
  mode": a question framed as "which approach" would otherwise skip the spec check. It cannot run
  commands, so claims like "tests pass" are "can't verify" unless the caller sends the output.
- **Advisor rules for records and process** (general, so no project needs its own): check the specific
  findings in the source, later reviews supersede earlier lists, aggregate counts do not satisfy
  per-item requirements, output files must be real output, records (status, checkboxes, folder,
  name) must agree, the implementer must not close what a reviewer must approve or edit a
  reviewer's text, uncommitted work is not done when commits are required.
- **Reviewer** covers code defects; **advisor** covers requirements. Their descriptions point at
  each other.
- **New files are part of the change.** `git diff` does not show untracked files, and coders create
  files; the orchestrator, reviewer and advisor are each told to check `git status` for them.
- **Jobs that call cortex (scripts, tests, direct requests).** Many tasks run code that sends its
  own requests to cortex, often for another model. Any orchestrator turn is a request to its own
  model, so a turn during such a job swaps models under it (the coordinator drains the job's current
  request, unloads its model and loads the orchestrator's; the job's next request swaps back). The
  orchestrator is told to recognise such jobs (cortex URLs and ports, `/v1/chat/completions`,
  `/api/generate`, an LLM client, a model setting; unknown = treat as one), run them in the
  foreground with the longest shell timeout, or in the background plus one blocking wait call
  (`while kill -0 <pid>; do sleep 30; done`), take no turns and dispatch no subagents until they
  end, and check `/availability` afterwards. Bot-marked scripts are held up to `HUMAN_HOLD` (120 s)
  after its last request; that pause is expected.
- **Orchestrator does not commit/push** unless asked, or the governing documents require it.
- **Orchestrator model must differ from the subagents' models** (mellum, qwen 128k-think-coder,
  gemma vision); the batching rules assume every subagent call is a swap away from it.
- **Orchestrator is groot-19b IQ3_M 128k-think-coder (decided).** It is also the primary coding
  agent in general use, and it is the fastest large-context model at both prefill and decode
  (1,453 / 61 t/s, fully on the GPU), which matters because it re-reads its context after every
  batch. On the easier fix benchmark it got both fixes and both reviews right. Its weak spot: on
  the hard fix benchmark it checked a flawed plan against the real data in only 1 of 2 clean runs.
  That is covered by design, not by choosing a stronger primary: the orchestrator reads the
  governing documents first, raon takes the tasks marked hard, and the advisor at the end checks
  the work against the sources and says so when the plan itself cannot meet the requirements.
- **End-only checking has a known cost.** When the mistake is in the plan, it is caught after the
  coders have built on it, and the fix is a re-plan and a second batch. Accepted to keep qwen swaps
  rare. If testing shows groot often mis-plans, one advisor plan check before the first coding
  batch would cost one qwen swap per task; revisit then.
- **Same model = no swap, but not simultaneous.** Every router runs `parallel = 1`, so subagents
  sharing a model are served one after another, and each may evict the others' cached prompt.
  Real concurrency needs `parallel = N` on a dedicated entry (llama.cpp splits `ctx-size` across
  the slots; changes what the bench measures; batch/ctx re-tuned) and/or the RAM prompt cache
  (`--cache-ram`, default on the pinned build unchecked). Both unmeasured; `models.ini` changes.
- **Fewer distinct models.** Each distinct model costs at least one swap per batch, so roles share
  models where quality allows (coder + scout; advisor + reviewer; hard-coder + thinker on raon).
  A task with routine and hard code costs two batches (mellum, raon): the orchestrator puts every
  hard task in one raon message and every routine task in one mellum message. Untested trade-offs
  that would save swaps: all code to raon (one fewer model; 4.5× slower decode, but measured
  quality, where mellum's is not); advisor/reviewer on raon (one fewer swap; loses independence,
  and raon's review record is 1/2).

### Model frequency (expected)

| Model | Role | Runs | Bench (full-metrics.md) |
|---|---|---|---|
| groot-19b 128k | orchestrator | every orchestrator step | GPU, 1,453 pp / 61 tg t/s |
| mellum-12b 128k | coder, scout | once per batch | GPU, 2,323 pp / 121 tg t/s |
| gemma-4-12b 64k-vision | vision | only when images are involved | **unbenched**; 32k-vision GPU 1,088 pp / 54 tg |
| qwen-3.6-35B 128k | advisor, then reviewer | only at the end of a task: advisor ≤ 3 rounds, then reviewer ≤ 2 | **unbenched**; 64k 1,329/39 and 256k 832/37, both CPU-placed |

## Verified facts (from the v2.2.5 binary, 2026-11-26)

- Permission rules: **last matching rule wins** (`findLast`), so deny-all-then-allow and the
  trailing deny patterns work.
- Permission actions seen: `edit`, `read`, `shell`, `webfetch`, `external_directory`, `question`,
  `execute`, MCP-resource actions; `subagent` is used in the existing files.
- Agents load from `{agent,agents}/**/*.md` (and `{mode,modes}/*.md` as primary); `mode: primary`
  is supported.
- Commands load from `{command,commands}/**/*.md` with fields `template`, `description`, `agent`,
  `model`, `subagent` (`subtask` deprecated); `$ARGUMENTS` is substituted (appended if absent).
- The container sees edits to `.local/opencode_data` directly (directory mount); a running OpenCode
  session may need a restart to pick up changed agent descriptions.

## Unverified (check during testing)

- Whether OpenCode v2 runs several subagent calls from one message together and returns all results
  in one continuation. Check the openresty log: one `switch:` to mellum per batch, not per task:
  `docker logs cortex-openresty-1 2>&1 | grep "switch:" | tail`
- Whether mellum's tool calls work **inside OpenCode** (a raw tool-call round trip through cortex
  works on b12785, 2026-11-26: it called `read_file` correctly and answered from the result).
- Whether the `read` tool passes image files to the vision model as images (`vision` depends on it).
- Whether `/orchestrate` leaves the session on the orchestrator afterwards, or only runs that one
  message as it. Tab selection is the reliable route.
- Whether a `/model` choice on the orchestrator persists across Tab switches. The `model:` line is
  the agent's default; a subagent without one inherits the caller's model (so the subagents must
  keep theirs).
- Coder/scout tasks on `parallel = 1` run one after the other and may evict each other's cached
  prompt; `--cache-ram` (RAM prompt cache) is not set in `models.ini` and its default in the pinned
  build is unchecked.
- Load times of groot, mellum, gemma and qwen (the swap cost).
- The OpenCode v2 shell tool's maximum timeout (the orchestrator's foreground-wait rule depends on
  it; each re-issued wait call is one short request to the orchestrator's model, i.e. a swap under a
  running cortex job).

## Open items / ideas (not done)

### Models (from the full-metrics.md review, 2026-11-26)

- **Advisor/reviewer model is untuned.** `qwen-3.6-35b-a3b-q4-mtp-128k-*` are `unverified` in
  full-metrics.md: never bisected or benched, `batch-size = 4096` set by hand. The 64k entry
  (benched) ran out of context in the advisor role, so 128k stays. **The 128k entry is to be
  benched.** Until then the ~99%-ctx saturation gate has not run on it.
- **Priority: test the checkers.** Because the design relies on the advisor and reviewer to catch
  the orchestrator's mistakes, their model deserves the most testing: bench the qwen-35B 128k entry
  (above), then run advisor candidates on a past review with known findings. On the evidence so
  far the qwen-3.6-35B family is mixed as a reviewer: nail-qwen reviewed 2/2 right on the easier
  benchmark but passed a wrong fix on the hard one.
- **Advisor alternative:** gpt-oss-20b 128k-think-high (1,502 pp / 44 tg, faster than qwen-35B,
  different family from the orchestrator). Quality unmeasured, and it **crashed** in the hard fix
  benchmark (cortex could not parse a reply: "does not match the expected peg-native format"), so
  its tool-call parsing on this llama.cpp build needs fixing first.
- **Test set for advisor models:** a past review with known findings. Give a candidate the state before that review and count the findings it catches.
- **Vision uses the 64k-vision entry,** copied from the 64k head with the projector; batch 1152 and
  MTP settings untuned with the projector, no bench record (32k-vision is benched). Bench it, or
  fall back to 32k-vision if it fails to load.
- **Coder/scout:** mellum 128k-think kept (fastest coding model; lfm-2.5-8b is faster but not a
  coder and 32k).

### Hard-coder / thinker subagent on raon (planned, not added)

One subagent on **raon-1-mini** with two modes: **hard-coder** (the coder's brief-and-report rules,
for tasks the orchestrator marks hard while planning, or that failed verification after mellum)
and **thinker** (a decision on a short, self-contained hard problem; no edits). One entry serves
both, so both modes share a model and may go in one message; it is its own message group
otherwise. Mellum stays the default coder (121 vs 27 t/s decode).

- **Evidence** (two private agentic fix benchmarks: a coding agent fixes a real bug with tools,
  scored on hidden tests or real data; one run per row unless noted):
  - **Easy fix set** (two bugs + two reviews): groot-19b IQ3_M 3/3 and 2/2, reviews 2/2; raon Q5
    3/3, reviews 1/2; raon Q4 failed its fix (added no test), reviews 1/2.
  - **Hard fix** (the issue's own plan is wrong; the model must check it against real data before
    following it). Clean runs, right / runs: **raon Q4 4/4, raon Q5 2/2**, cyber-tiel-coder-35b
    3/3 (one at the time limit with right code), tiel-coder-35b 1/1, qwen-3.6-35b base 1/1
    (48.8 min), glm-4.7-flash Q4 1/2, **groot IQ3_M 1/2** (plus 0/2 earlier on older prompts),
    groot Q4 0/1, saluki medium 0/1 (xhigh 2/2, 52-60 min), nail-qwen 0/1, raon Q6 0/1 (ruff
    failure). gpt-oss-20b think-high **crashed**: cortex could not parse its 31st reply ("does not
    match the expected peg-native format").
  - So raon is the most reliable fixer on the hard case, and both quants work; Q4 is slightly
    faster (27.5 vs 26.4 t/s) and 4/4 here but failed the easy fix once; Q5 passed both sets.
    Raon also completes agentic fixes with tools (in a different coding agent; OpenCode untested).
    Raon took 24-42 min per run, groot 13-16 min.
  - **mellum was in neither benchmark;** its coding quality here is the maintainer's judgement,
    not measured.
- **Speed:** raon 128k 552 pp / 27 tg (Q4) and 553 / 26 (Q5), CPU-placed (~1,440% CPU, 10.9 GB
  VRAM). Reading 10K tokens ~18 s (inkling ~100 s).
- **ctx: 64k,** set by the hard-coder mode (it reads files and loops on tools, and everything it
  reads stays in context). Budget: system + agent prompt ~2-4K (estimate), brief ~2-4K, files read
  ~10-20K, reasoning ~8-16K across turns (reasoning is always on in raon's entries), edit calls and
  tool results ~3-6K → ~25-50K. Output cap at 64k is the full 16,384 (`min(ctx/4, 16384)`); 48k is
  tight and caps output at 12,288; 32k fits the thinker mode only.
- **Why smaller ctx helps raon:** its entries have no `override-tensor`, so `-fit` places the model
  automatically; a smaller KV frees VRAM and `-fit` moves more of the model to the GPU with no hand
  tuning. Gain unmeasured. The bench overstates it as with any entry (prefill on a 75%-of-ctx
  prompt, decode on a 150-token prompt).
- **New entry:** `raon-1-mini-q5-64k-think-coder` (or Q4; see evidence), copied from the 128k
  `-think-coder` section
  (sampling 1.0 / 0.95 / 20, `presence-penalty 0.0`) with `ctx-size 65536`, then bisected and
  benched.
- **Unverified:** raon's OpenCode tool calls (the benchmarks used a different coding agent).

### Inkling (thinker candidate, second to raon)

inkling-2-mini is reported to be a strong model (unmeasured here) but is the slowest at prefill:
64k 98 pp / 20 tg, 96k 90 / 21, 128k 65 / 20 (benched before the build bump to b12651-mix-c7059d6,
not re-benched). It earns a separate thinker role only if it beats raon on non-coding reasoning.

- **Shape if added:** no tools (every tool result costs prefill at ~100 t/s); problem under ~4K
  tokens in the prompt; always alone in its message; returns brief reasoning, answer and
  confidence. Cost at 64k figures: ~30 s to read 3K tokens, ~6.5 min for 8K tokens out (lower
  bound at high effort).
- **Entry:** `inkling-2-mini-q4-32k-think-high`: `ctx-size 32768` (budget ~15-24K);
  `chat-template-kwargs = {"reasoning_effort": 0.9}` (current entries use 0.1, "minimal",
  third-party suggestion, unmeasured); `model-meta.json` `output: 16384` (the generator would cap
  32k at 8,192); re-tune `override-tensor` (12 expert blocks on CPU at 64k/96k, 14 at 128k, set by
  hand; `bench.sh` does not tune it) for the freed VRAM; then bisect and bench.

### Test before adding either

A few hard problems from real work, same prompt, on raon Q5 64k, inkling 32k at high effort,
qwen-35B think and gpt-oss-20b think-high; check correctness. Add the hybrid on raon if it holds
up; add an inkling thinker only if it clearly wins on reasoning. gpt-oss-high (1,502 pp / 44 tg at
128k) is the fast fallback for the thinker role (no tools there, so its reply-parsing crash may
not apply; check).

### qwen3.8-27B models (saluki, swift, dirk): fallback only

On the hard fix benchmark their reasoning is good but slow: saluki xhigh 2 right of 2 (1 completed,
52-60 min; medium 0/1), swift 114k 4 right of 4 (3 completed, 37-60 min), swift MTP 3 right of 3
(1 completed), dirk 4 right of 6 (1 completed cleanly, 2 blocked by harness bugs). They often run
out of time before the test and commit. Speed: 351-390 pp / 21-26 tg, fully on the GPU (dense 27B at
~2 bits). Raon (6 of 6, all completed, 24-42 min) covers the hard-coder and thinker roles better, and a
qwen3.8 model would be a sixth model to swap to. Reviews on the easier benchmark: saluki xhigh 1/2
(one no verdict), medium 0/2. Fallback: swift 114k as hard-coder if raon's tool calls fail in
OpenCode.

### Other

- **Swap cost: addressed by the slot cache** (implemented 2026-11-26,
  `md/plan-slot-cache-across-swaps.md`). A swapped-back model restores its last conversation:
  groot's follow-up processed 30 tokens instead of 51K (switch back ~9 s instead of ~27 s). It holds
  one conversation per model (the last at unload), which is the orchestrator's for groot. Still open:
  qwen-35B (advisor/reviewer) loads in ~38 s on b12785 even warm (see AGENTS.md Gotchas).
- If the end check (advisor ≤ 3 rounds, then reviewer ≤ 2) is too slow, lower the caps or skip the
  reviewer when no code changed.
- Coder/vision permissions are denylists; an allowlist (`*` deny, then read/edit) would be tighter,
  but the action names of the grep/glob/list tools are unverified.
- Project-specific rules (like a repo's closing checklist) could live in that repo's own OpenCode
  config folder rather than AGENTS.md; where v2 looks for a project-level folder is unverified.
- Not recommended: a long-context reader on qwen-3.5-9b 256k (838 pp; a full 256k read ~5 min);
  project-specific skills (e.g. translation) — the setup is project-agnostic.

## Change log

- **2026-11-26** — `advisor.md` rewritten: source-of-truth first on every request, caller claims
  checked, can't-verify for commands, output/records/process rules; read-only git permissions
  hardened (`git ls-files`, `git blame`, deny chaining/redirects/`--output`).
- **2026-11-26** — `reviewer.md` description scoped to code diffs, pointing requirement checks to
  the advisor.
- **2026-11-26** — added `coder.md`, `orchestrator.md`, `commands/orchestrate.md`. Orchestrator
  calls advisor + reviewer together automatically at the end.
- **2026-11-26** — removed the `@vocweb/opencode-advisor` plugin: `plugins` key deleted from
  `opencode.json`, `WATCHDOG.yml` deleted, cached packages `@vocweb/opencode-advisor@0.2.0` and
  `oc-advisor@latest` deleted from the container's `~/.cache/opencode/npm`. Its `turn` reviews
  (every 10 turns, qwen 64k) would have swapped models mid-batch.
- **2026-11-26** — deleted `md/plan-opencode-advisor-plugin.md` (untracked, obsolete after the
  plugin removal).
- **2026-11-26** — `orchestrator.md`: advisor and reviewer only in step 7 (end of task), never
  mid-task.
- **2026-11-26** — added `agents/scout.md` (mellum, read-only, git read commands as the advisor),
  `agents/vision.md` (gemma 64k-vision, read-only), `commands/review.md` (`/review`). Orchestrator:
  model groups per message (coder+scout, advisor+reviewer, vision), scouts for broad searches,
  vision for images. Open items rewritten from the full-metrics.md model review.
- **2026-11-26** — added `commands/verify.md` (`/verify`, advisor as subagent) and
  `commands/handoff.md` (`/handoff`, current agent; structure mirrors this document).
- **2026-11-26** — final cross-file pass:
  - `reviewer.md`: added the read-only guards the advisor and scout have (deny chaining,
    redirects, `$(`, `--output`; it could previously run `git diff --output=FILE` or chain commands
    after `git status`); `git ls-files` allowed; the base diff is now `git diff main...HEAD`
    (three-dot diffs from the merge base without `$(...)`, which the guards block); new untracked
    files are read as part of the change.
  - `orchestrator.md`: briefs name files to change **or create**; verification reads new untracked
    files as well as `git diff`.
  - `coder.md`: may create the files the brief names; its report marks new files.
- **2026-11-26** — open items: thinker subagent plan (inkling 32k at high reasoning effort).
- **2026-11-26** — open items: raon hard-coder/thinker hybrid (64k, Q5 preferred) as the main
  candidate, inkling thinker second; evidence from the one coding benchmark record found added.
- **2026-11-26** — open items: evidence from the hard fix benchmark added (raon Q4 4/4, Q5 2/2;
  groot 1/2; cyber-tiel 3/3; gpt-oss crashed on reply parsing); cyber-tiel 128k as orchestrator
  candidate.
- **2026-11-26** — decisions recorded: groot stays orchestrator (speed, also the primary coding
  agent; mistakes are expected and caught by the checkers); orchestrator candidates (cyber-tiel and
  others) removed. Added: the "primary is expected to err" principle, checkers as test priority,
  the end-only checking trade-off, same-model-is-sequential and fewer-models design notes, and the
  qwen3.8-27B review (fallback only).
- **2026-11-26** — open items: pointer to `md/plan-slot-cache-across-swaps.md`.
- **2026-11-26** — from testing: `orchestrator.md` step 7 now calls the advisor alone until its
  verdict is `PASS` (≤ 3 rounds), then the reviewer alone (≤ 2 rounds), never together; `advisor.md`
  verdict line is `PASS` / `NOT PASSED` / `CAN'T VERIFY` when checking work.
- **2026-11-26** — `orchestrator.md`: new section "Commands that use the inference engine": stay
  idle (no turns, no subagents) while a script or request that calls cortex runs; how to recognise
  and how to wait.
- **2026-11-26** — final pass: `orchestrator.md` model-group rule reworded (advisor/reviewer share
  a model but are called one at a time); its own test runs and the advisor's requested commands now
  point to the cortex-job rule. Handoff model table and caps item updated to the sequential check.
- **2026-11-26** — the `llama-cpp` router moved to upstream b12785 (`md/llama-cpp-b12785-quick-ab.md`):
  groot and mellum tool-call round trips verified; the slot-cache plan's Phase 0 passes on it.
- **2026-11-26** — slot cache live on all four llama.cpp routers; swap-cost item updated.
