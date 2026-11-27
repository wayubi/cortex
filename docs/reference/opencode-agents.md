# OpenCode agents and commands

The orchestrator, its subagents and the commands in `opencode/agents/` and `opencode/commands/`:
what each does, why it is built that way, what has been verified, and what is still open. Update it
when the design changes; the history of changes is in git.

## Goal

- An **orchestrator** primary agent owns a task end to end: reads the governing documents, plans,
  sends independent fixes to fast **coder** subagents, verifies, and has the **advisor** and
  **reviewer** check the work automatically when it is done.
- Subtasks of one stage go out **in one batch**, so the orchestrator wakes once per stage, not once
  per subtask.
- The **advisor** is a critical second opinion from first principles: it finds the source
  documents itself, treats the caller's claims as claims, and checks the work against them. It
  needs **no project-specific instructions**.
- **Project-agnostic.** Used across many projects; nothing depends on one project's `AGENTS.md`.
- **Few model swaps** on the single GPU: the coordinator unloads the resident model whenever the
  requested model changes.
- A **foreman** primary agent owns work orders: it triages open issues into ranked work orders and
  gives each finished work order its final review, accepting it or returning it with findings. The
  agent that writes a work order is the one that judges it; the builder never closes its own work.
- **The primary is expected to make mistakes.** The advisor and reviewer exist to catch them, so
  the checkers' quality matters more than the orchestrator's.

## The agents and commands

Tracked in `opencode/agents/` and `opencode/commands/`, bind-mounted read-write over
`/root/.config/opencode/agents` and `/commands` in the `opencode` container (edits made from inside
OpenCode land in the working tree; review them with git). The rest of the config (`opencode.json`,
machine-specific skills) stays in the config volume.

| File | Kind | Model | What |
|---|---|---|---|
| `agents/orchestrator.md` | primary | inkling-2-mini-q4-96k-think-loopgpu | plans, batches subagents, quick-checks their work, then advisor until PASS, then reviewer |
| `agents/coder.md` | subagent | mellum-2.1-12b-a2.5b-q4-128k-think | makes file changes (code, data, documents) from a complete brief; only the named files |
| `agents/scout.md` | subagent | mellum (same entry) | read-only search; answers with `path:line` evidence |
| `agents/vision.md` | subagent | gemma-4-12b-q4-qat-mtp-64k-vision | reads images for the text-only agents |
| `agents/advisor.md` | subagent | nail-qwen3.6-35b-a3b-q4-mtp-128k-think-coder | checks work and plans against the source documents; verdict `PASS` / `NOT PASSED` / `CAN'T VERIFY` |
| `agents/reviewer.md` | subagent | nail-qwen (same entry) | reviews the code changes for defects |
| `agents/foreman.md` | primary | nail-qwen (same entry) | triages issues into ranked work orders; final review of a work order: accepted or returned |
| `commands/orchestrate.md` | `/orchestrate <task>` | | runs the task as the orchestrator |
| `commands/review.md` | `/review [focus]` | | reviewer on uncommitted changes (else branch vs base) |
| `commands/verify.md` | `/verify [docs / focus]` | | advisor against the source documents |
| `commands/triage.md` | `/triage [scope]` | | the foreman proposes work orders and a ranking; writes on approval |
| `commands/accept.md` | `/accept <work order>` | | the foreman's final review: accepted, or returned with a new review round |
| `commands/handoff.md` | `/handoff [topic]` | | the current agent writes a `handoff-<topic>.md` in the project's planning folder (no swap) |

### Permissions

Kept short on purpose: earlier pattern lists (read-only git allow-lists, anchored deny lists,
special-character denies) kept refusing the agents' real work. Safety rests on the instructions
("change nothing") plus git, which shows any change.

| Agent | Edit tool | Shell | Also denied |
|---|---|---|---|
| advisor, reviewer, scout | no | **allowed**, except `rm`, `git push`, `git reset --hard`, `git clean`, `sudo`, `docker` | subagent; repeated failing calls (`doom_loop`) |
| coder | yes | none (it edits to a brief; the orchestrator runs the checks) | subagent; `question` (would block a batch); `doom_loop` |
| vision | no | none | subagent; `doom_loop` |
| foreman | yes, by instruction only tracker records | **allowed**, except the checkers' list and `git commit` | subagent; `doom_loop` |
| orchestrator | OpenCode defaults (no rules) | | |

OpenCode checks each part of a chained command (`a && b`, `a | b`, `a; b`) on its own; the last
matching rule wins. The advisor and reviewer record `git -C <repo> status --porcelain` before and
after running project code and report any change a command made.

## Flow

1. Select `orchestrator` (Tab) in a **fresh session**, or run `/orchestrate <task>`. Switching a
   long `build` session to the orchestrator mid-way led it to keep editing everything itself.
2. It reads the governing documents and the code; broad searches go to `scout` batches, images to
   `vision` (its own message).
3. It lists every fix and groups them by file. **Two or more independent groups** (different files,
   no fix needing another's result) go to coders, one per group, each with a complete brief (files,
   change, for data fixes the rule and source text, constraints, done-when). **A single fix, fixes
   that build on each other, or fixes in one file** it makes itself.
4. Every coder task of a batch goes **in one message**; it waits for all of them.
5. **Quick check, not a review:** each coder's report and diff against its brief (only its files,
   every item done, nothing extra, no placeholders). Small gaps it fixes itself; larger ones go back
   as a follow-up batch. Then it runs the project's quick checks so their output can go to the
   advisor.
6. When it believes it is done: the **advisor alone**, with document and data paths, the diff,
   the full output of every script, scorer or test the documents name, and its claims; it fixes
   findings until the verdict is `PASS` (at most three rounds, else it reports the open findings
   and skips the reviewer). Then the **reviewer alone**; Critical/High findings fixed (at most two
   rounds), and the advisor asked once more if a fix changes behaviour a requirement covers.
7. Its report answers or escalates every item of the latest review.

### Work orders

**Every step in a fresh session (`/new`).** The work order file is the hand-off: the foreman judges
the record and the repository, not the builder's conversation; a builder that needs earlier chat
shows the work order is incomplete; and switching agents in one session sends its whole history to
the other model (nail-qwen re-reading the orchestrator's session). A command's `agent:` may switch only that
message, inside the current session, so `/accept` typed in the builder's session would see its
history.

1. `/triage [scope]`: the foreman reads the open issues (plans only when named) and the code they
   touch, leaves out what needs a decision, lacks evidence or should be closed, groups the rest
   (shared files or area, dependencies, shared checks; about five issues or one coherent change per
   work order; overlapping work orders made sequential), and ranks all open work orders (severity,
   then unblocking, then cost). It proposes and waits; on approval it writes the work orders from the
   template, adds the `**Work order:**` back-links and updates `tracker/work-orders/triage.md`.
2. `/orchestrate <work order>`: the orchestrator builds as usual and writes its report into the work
   order as `Report back, round N`, changing nothing else there.
3. `/accept <work order>`: the foreman runs the PASS CHECKLIST itself, checks the diff from `Base`
   against the scope and every included issue's acceptance criteria, and rules on the builder's
   questions. **Accepted:** a review round with the results, the work order and the items it fully
   covered moved to `resolved/`, the index updated. **Returned:** a review round with numbered
   blocker and nit findings, rulings and any amendments; back to step 2. After three returned
   rounds it asks the user. New defects outside the scope become new issues.

## Why it is built this way

- **Batches.** Each delegation swaps the orchestrator's model out and mellum in, and back. The slot
  cache restores the orchestrator's processed conversation after a swap (measured on groot: ~9 s
  instead of re-reading ~51K tokens; it matters more on inkling, which reads ~90 tokens/s), but every
  swap is still a load each way, and only one conversation per model survives a swap. Subagents
  sharing a model in one batch take turns in a single slot without re-reading: llama.cpp's RAM
  prompt cache (`--cache-ram`) keeps each one's prompt (measured on mellum: 21 tokens re-processed
  instead of 19K). One batch per stage means one wake-up instead of one per task.
- **One model per message.** Mixing models in one message swaps between requests. Coder + scout
  share mellum; vision goes alone; advisor and reviewer share nail-qwen but are called one at a
  time. Two differently named models.ini entries swap even with the same weights, so agents that
  share a model use the identical entry name.
- **The orchestrator's model differs from every subagent's**; the batching rules assume each
  subagent call is a swap away from it.
- **Advisor before reviewer, never together.** Reviewing code that does not yet meet the
  requirements is wasted, and its findings can conflict with the advisor's fixes. (Speed is not
  the reason: on one model both would keep their prompts, with the same two swaps.)
- **Advisor and reviewer only at the end**, never while planning or between batches: each call is
  a swap to a CPU-placed 35B. The cost is that a wrong plan is caught after the coders built on it;
  if the orchestrator often mis-plans, one advisor plan check before the first batch would cost one swap.
- **The orchestrator fans out independent fixes but keeps its edit tools.** In a real round groot made every fix
  itself under the old wording ("tiny edits" allowed, "code writing" delegated, while the fixes
  were labels and records). The rule is now explicit, and the coder handles any file change.
- **Advisor and reviewer run checks themselves.** Read-only, the advisor answered "can't verify"
  for every claim that needs a script's or test's output, exactly the claims an independent check
  matters most for. They run them without changing anything, and compare with the orchestrator's
  output; a difference is a finding.
- **Model-independent file access.** An advisor (qwen, later nail) reported existing files missing:
  paths relative to a folder the orchestrator had `cd`'d into, file search honouring `.gitignore`,
  shell commands refused, the repository in a subfolder. Fixed with absolute paths in every
  subagent prompt, a shell for the checkers, "a failed search is not proof of absence" (report
  **can't verify** and ask for the absolute path), and `git -C <folder>`. The coder reports a missing
  file as a question instead of creating it at the wrong path.
- **A refused command is never retried.** nail repeated one refused command ~60 times; the agents
  are told to do it another way or report it, and `doom_loop` is denied as a backstop.
- **Advisor re-derives and covers every review request.** An external review of a real round found
  a label "fixed" by applying the rule backwards, and a requested ruling left unanswered. The
  advisor now applies the rule itself to the underlying data for each corrected item (all up to
  ~20, else a stated sample) and gives `NOT PASSED` for any request of the latest review the work
  does not answer.
- **Advisor rules for records and process** (general, so no project needs its own): later reviews
  supersede earlier lists, counts do not satisfy per-item requirements, output files must hold real
  output, records (status, checkboxes, folder, name) must agree, the implementer must not close what
  a reviewer approves or edit a reviewer's text, uncommitted work is not done when commits are
  required.
- **Reviewer covers code defects, advisor covers requirements;** their descriptions point at each
  other. Both, and the orchestrator, read untracked files (`git status`), since coders create files
  `git diff` does not show.
- **Coder has minimal tools.** mellum is a good coder but poor at agentic work, so the orchestrator
  explores, runs and verifies; the coder follows a brief and puts questions in its report.
- **Jobs that call cortex.** Any orchestrator turn is a request to its own model, so a turn while a
  script or test is sending requests to cortex swaps models under it. The orchestrator recognises
  such jobs (cortex URLs, `/v1/chat/completions`, an LLM client, a model setting; unknown = treat as
  one), runs them in one blocking call, and takes no turns or subagent calls until they end.
  Bot-marked scripts may be held up to `HUMAN_HOLD` (120 s) after its last request; that is expected.
- **Inkling as orchestrator** (inkling-2-mini 96k, the user's choice on 2026-11-27; groot before).
  Benched at 21 t/s decode and 90 t/s prefill, CPU-resident: a fresh session that reads ~50K tokens
  spends ~10 min reading, and the slot cache saves it from repeating that after each subagent swap.
  It differs from every subagent's model, which the batching rules assume. Its planning quality as
  orchestrator is unmeasured. groot (61 / 1453 t/s, GPU) was the previous choice: fastest
  large-context model, 1 of 2 right on a hard benchmark.
- **The orchestrator does not commit or push** unless asked or the documents require it.
- **The foreman is separate from the orchestrator and the advisor.** It writes the contract and
  judges against it, so it must not be the builder (it could "fix" what it judges: it edits only
  tracker records) nor a subagent the builder calls (the builder would choose when it is asked and
  what it is shown). It is a primary the user runs, on the checkers' model, because triage and
  acceptance are judgement, not code. It may run shell commands (the checklists need them) but not
  commit: the user commits.
- **Work-order records are append-only.** Builder reports and foreman reviews are added as numbered
  rounds and never edited; a wrong work order is corrected by an amendment in a review round. The
  history of what was asked, claimed and ruled stays readable, as the advisor's record rules expect.
- **Three returned rounds, then the user.** A work order that fails three reviews is usually wrong
  itself (too big, or a bad rule); another round would not fix that.

## Verified

From the OpenCode v2.2.5 binary (2026-11-26; the container now runs a later v2):
- Permission rules: the **last matching rule wins**.
- Agents load from `{agent,agents}/**/*.md`; `mode: primary` is supported. Commands load from
  `{command,commands}/**/*.md` with `template`, `description`, `agent`, `model`, `subagent`;
  `$ARGUMENTS` is substituted (appended if absent).
- Shell commands are split at unquoted `;`, `&&`, `|`, and each part is checked separately.
- File search (glob) honours `.gitignore`.
- A running OpenCode session may need a restart to pick up changed agent files.

Measured:
- Two sessions on one model keep their prompts between turns (RAM prompt cache, mellum).
- A raw tool-call round trip through cortex works for groot and mellum on llama.cpp b12785.

## Unverified (check in real sessions)

Session data for checking these is in the config volume (`share/opencode/opencode.db`: tables
`session_v2` for subagent sessions by `agent`, `session_message` for tool calls and their status);
copy it out before reading. The openresty log shows the swaps:
`docker logs cortex-openresty-1 2>&1 | grep "switch:" | tail`.

- The orchestrator fans out independent fixes (look for `switch:` to mellum in a multi-fix round),
  and OpenCode runs a batch's subagent calls together (one switch per batch, not per task).
- Subagents get absolute paths (advisor sessions no longer open with `File not found` reads).
- mellum's tool calls work inside OpenCode.
- The `read` tool passes images to the vision model as images.
- `doom_loop: deny` stops a subagent that repeats a failing call, and after how many.
- `/orchestrate` leaves the session on the orchestrator afterwards, or only that one message.
- A `/model` choice on the orchestrator persists across Tab switches.
- The RAM prompt cache keeps several conversations on nail-qwen as it does on mellum.
- The shell tool's maximum timeout (the cortex-job rule depends on it).
- The foreman, not yet run: nail-qwen as a primary agent (tool calls and long sessions), whether it
  keeps to tracker records with the edit tool allowed, the grouping and ranking quality of
  `/triage`, and whether `/accept` catches a planted defect (try a work order with a known missed
  check).

## Open items

### Models

- **The checkers' model is benched, not yet judged.** The nail-qwen 128k entry has a bench record
  (38 t/s decode, 1258 t/s prefill, CPU-resident; benched on the build before b12785). Try advisor
  candidates on a past review with known findings (give a candidate the
  state before the review and count the findings it catches). On the evidence so far the qwen-3.6-35B
  family is mixed as a reviewer: nail-qwen reviewed 2/2 right on an easier benchmark but passed a
  wrong fix on a hard one.
- **Advisor alternative:** gpt-oss-20b 128k-think-high (faster, a different family). Quality
  unmeasured, and it crashed in a benchmark on b10622 (cortex could not parse a reply: "does not
  match the expected peg-native format"); re-test on b12785.
- **Vision uses the 64k-vision entry**, untuned with the projector and unbenched (32k-vision is
  benched). Bench it, or fall back to 32k-vision.
- **Coder/scout:** mellum 128k-think kept (fastest coding model).

### Hard-coder / thinker subagent on raon (planned, not added)

One subagent on **raon-1-mini** with two modes: **hard-coder** (the coder's rules, for tasks the
orchestrator marks hard or that failed verification after mellum) and **thinker** (a decision on a
short, self-contained hard problem; no edits). Mellum stays the default coder (121 vs 27 t/s decode).

- **Evidence** (two private agentic fix benchmarks, one run per row unless noted): on the hard fix
  (the issue's own plan is wrong and must be checked against real data) raon Q4 4/4 and Q5 2/2
  right, cyber-tiel-coder-35b 3/3, groot IQ3_M 1/2, nail-qwen 0/1; raon took 24-42 min per run,
  groot 13-16 min. On the easier set raon Q5 passed both fixes, Q4 failed one. mellum was in
  neither benchmark.
- **Entry:** `raon-1-mini-q5-64k-think-coder`, copied from the 128k `-think-coder` section with
  `ctx-size 65536`, then bisected and benched. 64k budget: prompt and brief ~4-8K, files ~10-20K,
  reasoning ~8-16K, tool results ~3-6K; output cap 16,384. A smaller ctx lets `-fit` move more of
  the model to the GPU (gain unmeasured).
- **Unverified:** raon's tool calls inside OpenCode (the benchmarks used a different agent); raon
  on upstream b12785 was 21-30% slower at prefill (one sample), so it stays on its own router.

### Inkling (thinker candidate, second to raon)

inkling-2-mini is the slowest at prefill (64k 98 pp / 20 tg). A thinker role only if it beats raon
on non-coding reasoning: no tools, problem under ~4K tokens, always alone in its message. Entry
`inkling-2-mini-q4-32k-think-high` (`reasoning_effort` 0.9, `model-meta.json` `output: 16384`,
`override-tensor` re-tuned by hand for the freed VRAM), then bisected and benched.

**Before adding either:** a few hard problems from real work, same prompt, on raon Q5 64k, inkling
32k high, nail-qwen think and gpt-oss-20b think-high.

### qwen3.8-27B (saluki, swift, dirk): fallback only

Good but slow reasoning on the hard fix (often out of time before testing and committing), and a
sixth model to swap to. Fallback: swift 114k as hard-coder if raon's tool calls fail in OpenCode.

### Other

- If the end check (advisor ≤ 3 rounds, reviewer ≤ 2) is too slow, lower the caps or skip the
  reviewer when no code changed.
- Project-specific rules could live in a project's own OpenCode config folder rather than its
  `AGENTS.md`; where v2 looks for one is unverified.
- Not recommended: a long-context reader on qwen-3.5-9b 256k (a full read ~5 min); project-specific
  skills (the setup is project-agnostic).
