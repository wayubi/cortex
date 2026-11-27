# Handoff: OpenCode agents, commands and skills

**Started:** 2026-11-26
**Last updated:** 2026-11-26 (late)
**Status:** In testing. First finding (2026-11-26): calling advisor and reviewer together was
slow; changed to advisor until `PASS`, then reviewer. The cortex side changed the same day (new
llama.cpp builds, the slot cache, NVMe-cache eviction): see "Infrastructure the agents run on".

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

The agents and commands are **tracked in this repository** under `opencode/agents/` and
`opencode/commands/` (moved 2026-11-26), and `compose.yml` bind-mounts them read-write (so OpenCode
can edit them; review with git) over
`/root/.config/opencode/agents` and `/commands` in the `opencode` container. The rest of the global
config (`opencode.json`, the machine-specific `chrome-web` skill) stays in the machine-local config
volume (`.local/opencode_data/`, gitignored), mounted at `/root/.config/opencode`. Until the
`opencode` container is next recreated it still reads the older copies in `.local/opencode_data/`
(identical at the time of the move); edit only the tracked copies. OpenCode version in the
container: **v2.2.5**.

| File | Kind | Model | What |
|---|---|---|---|
| `opencode/agents/orchestrator.md` | primary | groot-19b-a3b-iq3m-mtp-128k-think-coder | plans, batches subagents, verifies, then advisor until PASS, then reviewer |
| `opencode/agents/coder.md` | subagent | mellum-2.1-12b-a2.5b-q4-128k-think | writes code from a brief; only the named files |
| `opencode/agents/scout.md` | subagent | mellum (same entry as coder) | read-only search, answers with `path:line` evidence |
| `opencode/agents/vision.md` | subagent | gemma-4-12b-q4-qat-mtp-64k-vision | reads images for the text-only agents |
| `opencode/agents/advisor.md` | subagent | qwen-3.6-35b-a3b-q4-mtp-128k-think-coder | checks work/plans against source documents |
| `opencode/agents/reviewer.md` | subagent | qwen (same entry as advisor) | reviews the code changes for defects |
| `opencode/commands/orchestrate.md` | `/orchestrate <task>` | — | runs the task as `orchestrator` |
| `opencode/commands/review.md` | `/review [focus]` | — | `reviewer` as a subagent on uncommitted changes (else branch vs base) |
| `opencode/commands/verify.md` | `/verify [doc paths / focus]` | — | `advisor` as a subagent against the source documents |
| `opencode/commands/handoff.md` | `/handoff [topic or path]` | — | current agent writes/updates `handoff-<topic>.md` in the project's planning folder (no swap) |
| `.local/opencode_data/skills/chrome-web/SKILL.md` | skill | — | browser skill; machine-specific, not tracked; independent of the agents |
| `.local/opencode_data/opencode.json` | config | — | providers (generated) + `mcp`; no `plugins` key any more |

### Permissions (what each subagent can do)

Simplified 2026-11-26: the earlier pattern lists (read-only git allow-lists, `git -C` variants,
anchored deny lists, special-character denies) kept blocking the agents' real work, so they were
replaced by short rules. Safety rests on the instructions ("change nothing") plus git, which shows
any change.

| Agent | Edit tool | Shell | Other denied |
|---|---|---|---|
| advisor, reviewer, scout | no | **allowed**, except `rm`, `git push`, `git reset --hard`, `git clean`, `sudo`, `docker` | subagent; repeated failing calls (`doom_loop`) |
| coder | yes | none (it edits to a brief; the orchestrator runs the checks) | subagent, question (would block a batch), `doom_loop` |
| vision | no | none | subagent, `doom_loop` |
| orchestrator | OpenCode defaults (no rules) | | |

OpenCode checks each part of a chained command (`a && b`, `a | b`, `a; b`) on its own, and the last
matching rule wins. The advisor and reviewer record `git -C <repo> status --porcelain` before and
after running project code and report any change a command made.

## Infrastructure the agents run on (cortex, as of 2026-11-26)

- **Builds:** the `llama-cpp` router (groot, mellum, qwen-35B, gemma) runs upstream **b12785**
  (`md/llama-cpp-b12785-quick-ab.md`); prism `prism-b12232-f702476`; raon KRAFTON `fb895662d`;
  inkling Unsloth b12651. The bench records in `full-metrics.md` are mostly from the old b10622;
  the quick A/B on b12785 measured groot 2,782 pp / 61.5 tg, mellum 3,726 / 108, qwen-35B 64k
  1,144 / 42 (one sample each, ~6K-token prompt).
- **Slot cache** (`md/plan-slot-cache-across-swaps.md`, AGENTS.md): before a model is unloaded its
  slot (KV cache + context checkpoints) is saved to RAM, and restored after its next load. A model
  swapped back processes only its new tokens: groot's follow-up after a qwen swap processed 30
  tokens instead of 51K; switching back to groot takes ~9 s in all (load ~4-7 s, save and restore
  0.1-0.4 s each) instead of ~27 s. One conversation per model is kept (the last at unload): for
  groot that is the orchestrator's; for mellum, whichever coder ran last. Files expire 2 h after
  their save; caps 8 GB (llama-cpp) and 2 GB per other router, RAM only for files written.
- **NVMe cache:** a model file on the NVMe loads fast (qwen-35B 8 s), one on the SSD slowly
  (qwen-35B 38-64 s). Copies are evicted by a **use score** (each load in the last 7 days counts
  `0.5 ** (age / 24 h)`), so a one-off load cannot push out a model in daily use and a model no
  longer used fades out within days.
- **Measured loads (warm):** groot ~4-7 s, mellum 2-3 s, qwen-35B 128k 8 s (NVMe), gemma vision
  ~5 s.

## Design

### Flow

1. Select `orchestrator` (Tab / agent picker), or runs `/orchestrate <task>`.
2. Orchestrator reads the governing documents (project instructions, spec, work order, issues,
   review rounds) and the code; broad searches go to `scout` batches, images to `vision` (own
   message).
3. It lists every fix the work needs (code, data, documents) and groups them by file. **Two or more
   independent groups** (different files, no fix needing another's result) go to coders, one per
   group, with a complete brief each (Files / Change, with the rule and source text for data fixes /
   Constraints / Done when). **A single fix, fixes that build on each other, or fixes in one file**
   groot makes itself. Groot keeps its own edit tools.
4. It sends **every coder task of a batch in one message** and waits for all of them.
5. **Quick check, not a review:** for each coder, its report and diff against the brief (only its
   files, every item done, nothing extra, no placeholders); groot fixes small shortcomings itself
   and sends larger ones back as a follow-up batch. Then it runs the project's quick checks so their
   output can go to the advisor.
6. When it believes it is done, it checks automatically, **advisor first, reviewer second, never
   together**. It calls the `advisor` alone (document paths, diff, command output, its claims) and
   goes back and forth, fixing findings and sending what it could not verify, until the advisor's
   verdict line is `PASS` (at most three rounds; otherwise it reports the open findings and skips
   the reviewer). Then it calls the `reviewer` alone, fixes Critical/High findings (at most two
   rounds), and re-asks the advisor once if a reviewer fix changes behaviour a requirement covers.
   A finding is resolved by a fix or by evidence that it is wrong.

### Why each choice

- **Batches.** Each delegation unloads groot and loads mellum, then groot reloads. Before the slot
  cache groot also re-read its whole context (~23 s per 51K tokens); now it restores it, so a
  wake-up costs ~9 s. Batching still matters: every swap is still a load each way, the slot cache
  keeps only one conversation per model across a swap, and subagents sharing a model in one batch
  still take turns in a single slot (without re-reading: the RAM prompt cache keeps each one's
  prompt). One batch per stage means one wake-up instead of one per task.
- **One model per message.** Mixing models in one message swaps between requests. Groups that may
  share a message: coder + scout (mellum); vision alone (gemma). Advisor and reviewer share a model
  (qwen) but are called one at a time (below). Any two
  differently named models.ini entries swap, even with the same weights, so the sharing agents use
  the identical entry name.
- **Advisor before reviewer, one at a time (decided, kept 2026-11-26).** The reason is the work:
  reviewing code that does not yet meet the requirements is wasted, and its findings can conflict
  with the advisor's fixes. Speed is no longer a reason: calling both together was slow in testing
  on b10622 (cause not measured), but on b12785 two sessions on one model do **not** cost each
  other their processed prompt (see "Same model = no swap"); together they would take about the
  same total time as in sequence, with the same two swaps (both run on qwen). A possible middle
  ground, not adopted: advisor alone until it passes, then advisor and reviewer together on the
  final round. Same model, so moving from advisor to reviewer is no swap. The advisor's verdict line is `PASS` / `NOT PASSED` / `CAN'T VERIFY` when it
  checks work, so the orchestrator has an unambiguous signal.
- **Advisor/reviewer only at the end** (orchestrator step 7; never while planning, between batches
  or when stuck): each call is a qwen swap. The advisor's description still says "when choosing an
  approach, or when stuck"; that is left for other primary agents (e.g. the built-in build agent).
- **Fan out only independent fixes; groot keeps editing** (2026-11-26). In a real orchestrated
  round groot made every fix itself and never called a coder: the old text let it do "tiny edits"
  and "small fixes" itself, said it delegates "code writing" (the fixes were labels and records),
  and the session had been switched to the orchestrator from hours of `build`-mode editing. The
  maintainer chose not to take groot's edit tools away: the rule is now explicit (independent
  file groups → coders in parallel; single, sequential or same-file fixes → groot), the coder makes
  any file change (code, data, documents) from a brief, and groot does a quick check of the coders'
  work (fixing small gaps itself) instead of a second full review. Start orchestrated work in a
  fresh session rather than switching agents mid-way.
- **Advisor and reviewer may run checks (option A, 2026-11-26).** Read-only, the advisor answered
  "can't verify" for every criterion that needs a script's or test's output, the claims an
  independent check matters most for, and contradicted its own rule never to accept "tests pass" on
  the caller's word. It now runs them itself, without changing anything (see Permissions); the
  orchestrator still sends its own output, and a difference between the two runs is a finding.
- **Refused commands and model-independent file access** (2026-11-26). With every route to a
  git-ignored folder closed (relative paths, search skipping ignored folders, `ls`/`find` refused,
  `git ls-files` outside the repository), qwen reported the files missing; later nail, given absolute
  paths, kept trying to *run* scripts and repeated one refused command ~60 times. Fixed so it does
  not depend on the model: read-only file commands allowed (they see ignored folders), "a refused
  command will be refused again: never retry it" in advisor, reviewer and scout, `doom_loop: deny`
  on all subagents as a backstop (exact trigger unverified), and the orchestrator sends the full
  output of every script, scorer or test the documents name.
- **Search is not proof of absence** (2026-11-26). An advisor declared a tracked file "does not
  exist": the project's `.gitignore` ignores the folder (its files were force-added), OpenCode's file
  search honours `.gitignore`, and the repository sat in a subfolder, so `git ls-files` (allowed only
  at the start of the command line) could not reach it. Now: absolute paths from the orchestrator;
  advisor, scout and reviewer report "can't verify: not found at the given path, and search skips
  ignored folders" and ask for the absolute path, never "does not exist"; `git -C <folder>` read
  commands allowed.
- **Absolute paths to subagents** (2026-11-26). Every advisor run opened with 3-6 `File not found`
  reads: groot had `cd`'d into a subfolder of the session's directory and wrote paths relative to
  it, while subagents start in the session's directory. The orchestrator now gives absolute paths in
  every subagent prompt and brief; the advisor, scout and reviewer search by name before calling a
  given path missing, and the coder reports a missing file as a question instead of creating it at
  the wrong path.
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
- **Advisor re-derives, and covers every review request** (added 2026-11-26 after an external
  review of a real orchestrated round found two misses: a label "fixed" by applying the contract's
  rule backwards, with wrong reasoning in the report; and a ruling the previous review asked for,
  left unanswered). The advisor now applies the rule itself to the underlying data for each
  corrected item (all items up to ~20, else a stated sample), treats the work's reasoning as a
  claim, and gives `NOT PASSED` for any request of the latest review the work does not answer. The
  orchestrator now passes the data and source paths for data changes, and its report covers every
  item of the latest review, escalating rulings it may not make as open questions with a proposed
  answer. Not yet known: whether the advisor had flagged these items in that round (its session log
  would show it).
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
- **Same model = no swap, served one at a time, prompts kept.** Every router runs `parallel = 1`,
  so subagents sharing a model take turns in one slot. Their processed prompts are **not** lost
  between turns: llama.cpp's in-process RAM prompt cache (`--cache-ram`, 8 GiB default, with
  `--cache-idle-slots`, both on by default in b12785) parks a conversation when another takes the
  slot and restores it when it returns. Measured on mellum (2026-11-26): A (19K tokens), then B
  (21K), then A's next turn processed **21 tokens** with 19,374 from cache (0.09 s), and the same
  for B. Not yet measured on qwen-35B (hybrid; same mechanism with context checkpoints). This
  cache lives in the model's process and is lost on unload; the slot cache then saves only the
  conversation in the slot (the last). Real concurrency would still need `parallel = N` on a
  dedicated entry (llama.cpp splits `ctx-size` across the slots; batch/ctx re-tuned; unmeasured).
  (An earlier version of this note said such sessions evict each other's prompt; that was
  inferred, not measured, and is wrong on b12785 for mellum.)
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
| groot-19b 128k | orchestrator | every orchestrator step | GPU, 1,453 pp / 61 tg t/s (b10622); quick A/B on b12785 2,782 / 61.5 |
| mellum-12b 128k | coder, scout | once per batch | GPU, 2,323 pp / 121 tg t/s (b10622); b12785 3,726 / 108 |
| gemma-4-12b 64k-vision | vision | only when images are involved | **unbenched**; 32k-vision GPU 1,088 pp / 54 tg |
| qwen-3.6-35B 128k | advisor, then reviewer | only at the end of a task: advisor ≤ 3 rounds, then reviewer ≤ 2 | **unbenched**; 64k 1,329/39 and 256k 832/37 (b10622), 64k 1,144/42 on b12785; CPU-placed |

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
- Whether the RAM prompt cache keeps several conversations on **qwen-35B** (advisor/reviewer) as it
  does on mellum (measured: yes). Test: two ~20K-token conversations alternated on qwen 128k, check
  `cache_n` on each second turn.
- The OpenCode v2 shell tool's maximum timeout (the orchestrator's foreground-wait rule depends on
  it; each re-issued wait call is one short request to the orchestrator's model, i.e. a swap under a
  running cortex job).
- Whether `doom_loop: deny` stops a subagent that repeats a failing call, and after how many.
- Whether OpenCode's permission matcher treats `*` as the simulation did (glob matching, `*` across
  spaces): the first advisor `git -C <folder> ls-files …` should run, and a `git -C … commit` be
  refused. If the matcher differs, the `git -C` allows or the write-subcommand denies may not apply
  as intended.
- Whether the orchestrator now fans out independent fixes to coders (look for `switch:` lines to
  mellum during a multi-fix round), and gives subagents absolute paths (advisor sessions should no
  longer open with `File not found` reads). Read-only check: copy
  `/root/.local/share/opencode/opencode.db*` out of the container and inspect `session_v2`
  (subagent sessions by `agent`) and `session_message` (tool calls and their status).

## Next steps (end of 2026-11-26)

In order of what unblocks the most:

1. **Recreate the `opencode` container** (`docker compose up -d opencode`) when convenient, so it
   reads the tracked agents and commands in `opencode/` instead of the older `.local/` copies.
2. **Test the agents in real OpenCode sessions** (start a fresh session as `orchestrator`; do not
   switch an existing `build` session) and settle the "Unverified" list: fan-out to coders, batched
   subagent calls (one `switch:` to mellum per batch), absolute paths, `git -C` in the advisor,
   images reaching `vision`, mellum's tool calls inside OpenCode, the shell tool's maximum timeout.
   Record each result here.
3. **Bench the checkers' model first:** `qwen-3.6-35b-a3b-q4-mtp-128k-*` (untuned, `batch 4096`), then
   the models the b12785 quick A/B flagged (qwen-3.6-35B family, groot, gemma-4-12B); then raon on
   b12785, which decides whether the raon router can go.
4. **Watch normal use:** slot-cache RAM per router over a day (`df -h /slot-cache`), prism's and
   inkling's 2 GB caps against their first `slot-cache: saved` lines, and the NVMe cache promoting
   cyber-tiel and nail-qwen on their next loads (`docker logs cortex-model-cache-1`).
5. **Only then:** the raon hard-coder/thinker subagent and the inkling thinker (below), after the
   comparison test.

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

- **Swap cost: done** (see "Infrastructure the agents run on"). Several coders on mellum do not
  re-read their prompts when they alternate within a batch (RAM prompt cache, measured); after a
  model swap only the last conversation comes back.
- **raon on b12785** (for the hard-coder plan): loads on upstream b12785 with the same answers as
  KRAFTON's build, but prefill was 21-30% slower there (one sample); raon stays on its own router
  until benched (`md/llama-cpp-b12785-quick-ab.md`).
- **gpt-oss-20b's reply-parsing crash** was on b10622; not re-tested on b12785.
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
- **2026-11-26** — prism-llama-cpp moved to `prism-b12232-f702476` (slot-cache support).
- **2026-11-26** — a 38-64 s qwen-35B load traced to an NVMe-cache eviction (not b12785); model-cache
  now evicts by a recency-weighted use score (half-life 24 h) instead of least recently loaded.
- **2026-11-26** — handoff: new section "Infrastructure the agents run on" (builds, slot cache, NVMe
  cache, measured loads); batches rationale, model table, unverified and open items updated.
- **2026-11-26** — handoff: "Next steps" section (what is left and in which order).
- **2026-11-26** — measured: two sessions on one model keep their prompts between turns (RAM prompt
  cache, mellum, 21 tokens re-processed instead of 19K); the note that they evict each other was
  wrong. Advisor-then-reviewer kept sequential for the work reason; "together" documented as costing
  no re-reads and no extra swap.
- **2026-11-26** — `orchestrator.md`: the batching rationale no longer says the orchestrator re-reads
  its whole conversation on resume (the slot cache restores it); it now gives the swap cost and that
  subagents sharing a model keep their progress between turns. The batching rules are unchanged.

- **2026-11-26** — agents and commands moved into the repository (`opencode/agents/`,
  `opencode/commands/`), bind-mounted read-only by `compose.yml`; the `.local/` copies kept until the
  container is recreated; the `chrome-web` skill stays machine-local.
- **2026-11-26** — `advisor.md` (re-derive corrected items from the data; every request of the latest
  review gets a verdict) and `orchestrator.md` (data paths to the advisor; answer or escalate every
  review item), in `opencode/agents/` and the `.local/` copy.
- **2026-11-26** — `orchestrator.md`: explicit fan-out rule (independent file groups → coders in one
  batch; single, sequential or same-file fixes → groot), data-fix briefs carry the rule and source
  text, step 6 is a quick check of the coders' work instead of a full verification. `coder.md`: makes
  code, data or document changes. Both copies.
- **2026-11-26** — absolute paths in every subagent prompt (`orchestrator.md`); path-not-found fallback in
  `advisor.md`, `scout.md`, `reviewer.md`, `coder.md`. Both copies.
- **2026-11-26** — `advisor.md`, `scout.md`, `reviewer.md`: a failed search is not proof of absence
  (search skips git-ignored folders), `git -C <folder>` read-only commands allowed, git write
  subcommands denied anywhere in the line; `coder.md`: a file not found is reported, not created.
- **2026-11-26** — handoff: permissions table shows `git -C` and the write-subcommand denies;
  unverified items for the permission matcher, fan-out and absolute paths (with how to check from the
  session database); next step 2 asks for a fresh orchestrator session.
- **2026-11-26** — advisor, reviewer, scout: read-only file commands allowed, never retry a refused
  command, `doom_loop: deny` (also coder, vision); orchestrator sends the full output of every named
  script; advisor and reviewer switched to nail-qwen 128k-think-coder. Not committed yet.
- **2026-11-26** — advisor and reviewer may run checks (option A) with file-changing commands denied
  (anchored); git-write denies scoped to git in advisor, reviewer and scout. Not committed yet.
- **2026-11-26** — removed the `;` `&` `|` deny patterns (they refused `python3 -c "import json;…"`);
  agents told to avoid `>`, `<`, backticks and `$(` in command text. Not committed yet.
- **2026-11-26** — permissions simplified for all subagents (see Permissions); the workaround text
  about refused characters and redirects removed from the instructions. Not committed yet.
