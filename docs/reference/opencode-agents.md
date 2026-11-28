# OpenCode agents and commands

The engineer, its subagents and the commands in `opencode/agents/` and `opencode/commands/`:
what each does, why it is built that way, what has been verified, and what is still open. Update it
when the design changes; the history of changes is in git.

## Goal

- An **engineer** primary agent owns a task end to end: reads the governing documents, plans,
  has fast **coder** subagents make the changes, verifies, and has the **advisor** and
  **reviewer** check the work automatically when it is done.
- Subtasks of one stage go out **in one batch**, so the engineer wakes once per stage, not once
  per subtask.
- The **advisor** is a critical second opinion from first principles: it finds the source
  documents itself, treats the caller's claims as claims, and checks the work against them. It
  needs **no project-specific instructions**.
- **Project-agnostic.** Used across many projects; nothing depends on one project's `AGENTS.md`.
- **Few model swaps** on the single GPU: the coordinator unloads the resident model whenever the
  requested model changes.
- A **triage** primary agent writes work orders: it triages open issues into ranked work orders.
  An **auditor** subagent, called by the engineer at the end, audits each finished work order and
  accepts and commits it or returns it with findings; the builder never closes its own work.
- **The primary is expected to make mistakes.** The advisor and reviewer exist to catch them, so
  the checkers' quality matters more than the engineer's.

## The agents and commands

Tracked in `opencode/agents/` and `opencode/commands/`, bind-mounted read-write over
`/root/.config/opencode/agents` and `/commands` in the `opencode` container (edits made from inside
OpenCode land in the working tree; review them with git). The rest of the config (`opencode.json`,
machine-specific skills) stays in the config volume.

| File | Kind | Model | What |
|---|---|---|---|
| `agents/engineer.md` | primary | inkling-2-mini-q4-96k-think-loopgpu | plans, has coders write the bulk of the code and makes the surgical edits itself, quick-checks their work, then advisor until PASS, then reviewer, then (work orders) auditor until accepted |
| `agents/coder.md` | subagent | mellum-2.1-12b-a2.5b-q4-128k-think | makes file changes (code, data, documents) from a complete brief; only the named files |
| `agents/scout.md` | subagent | mellum (same entry) | read-only search; answers with `path:line` evidence |
| `agents/vision.md` | subagent | gemma-4-12b-q4-qat-mtp-64k-vision | reads images for the text-only agents |
| `agents/advisor.md` | subagent | nail-qwen3.6-35b-a3b-q4-mtp-128k-think-coder | checks work and plans against the source documents; verdict `PASS` / `NOT PASSED` / `CAN'T VERIFY` |
| `agents/reviewer.md` | subagent | nail-qwen (same entry) | reviews the code changes for defects |
| `agents/triage.md` | primary | groot-19b-a3b-iq3m-mtp-128k-think-coder | triages issues into ranked work orders and keeps the triage index |
| `agents/auditor.md` | subagent | cyber-tiel-coder-35b-a3b-q4-mtp-128k-think-coder | audits a finished work order: accepted and committed, returned, amended, or needs the user |
| `commands/implement.md` | `/implement <work order, issue or task>` | | the engineer implements it; a work order or issue ends with the auditor |
| `commands/review.md` | `/review [focus]` | | reviewer on uncommitted changes (else branch vs base) |
| `commands/verify.md` | `/verify [docs / focus]` | | advisor against the source documents |
| `commands/triage.md` | `/triage [scope]` | | the triage agent proposes work orders and a ranking; writes on approval |
| `commands/audit.md` | `/audit <work order> [decision]` | | the auditor by hand (the engineer calls it itself after a build) |
| `commands/handoff.md` | `/handoff [topic]` | | the current agent writes a `handoff-<topic>.md` in the project's planning folder (no swap) |

### Permissions

Kept short on purpose: earlier pattern lists (read-only git allow-lists, anchored deny lists,
special-character denies) kept refusing the agents' real work. Safety rests on the instructions
("change nothing") plus git, which shows any change.

| Agent | Edit tool | Shell | Also denied |
|---|---|---|---|
| advisor, reviewer, scout | no | **allowed**, except `rm`, `git push`, `git reset --hard`, `git clean`, `sudo`, `docker` | subagent; repeated failing calls (`doom_loop`) |
| coder | yes | none (it edits to a brief; the engineer runs the checks) | subagent; `question` (would block a batch); `doom_loop` |
| vision | no | none | subagent; `doom_loop` |
| triage | yes, by instruction only tracker records | **allowed**, except the checkers' list and the bulk forms `git add -A`/`-u`/`.`, `git commit -a`/`--amend`, `git stash` | subagent; `doom_loop` |
| auditor | yes, by instruction only tracker records | as triage | subagent; `question` (it returns `NEEDS YOUR DECISION` instead); `doom_loop` |
| engineer | OpenCode defaults (no rules) | | |

OpenCode checks each part of a chained command (`a && b`, `a | b`, `a; b`) on its own; the last
matching rule wins. The advisor and reviewer record `git -C <repo> status --porcelain` before and
after running project code and report any change a command made.

## Flow

1. Select `engineer` (Tab) in a **fresh session**, or run `/implement <task>`. Switching a
   long `build` session to the engineer mid-way led it to keep editing everything itself.
2. It reads the governing documents and the code; broad searches go to `scout` batches, images to
   `vision` (its own message).
3. It lists every fix and groups them by file, one coder per file, each with a complete brief
   (files, change, for data fixes the rule and source text, constraints, done-when). Independent
   groups go in one batch; dependent work (tests on new code, callers) in a later batch. It makes a
   change itself only when it is small (a few lines, a coder's missed item, wiring), and its report
   says who made each change.
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

Two runs, each in a **fresh session** (`/new`): `/triage`, then `/implement <work order>`. The
work order file is the hand-off, so the engineer needs no earlier chat (one that does shows the work
order is incomplete), and switching agents in one session would send its whole history to the
other model.

1. `/triage [scope]`: the triage agent reads the open issues (plans only when named) and the code they
   touch, leaves out what needs a decision, lacks evidence or should be closed, groups the rest
   (shared files or area, dependencies, shared checks; about five issues or one coherent change per
   work order; overlapping work orders made sequential), and ranks all open work orders (severity,
   then unblocking, then cost). It proposes and waits; on approval it writes the work orders from the
   template, adds the `**Work order:**` back-links and updates `tracker/work-orders/triage.md`.
   Before saving a work order it checks it: named files and functions exist at `Base`, quotes match
   the issues, every checklist command runs, and every issue criterion has a check the work order's
   rules allow (a conflict goes to the user in the proposal); and any two open work orders that
   change the same file, or whose checks measure what the other changes, are linked as
   predecessors. Approvals the user gives are written into the work order; commands are the ones
   the agents can run (no `docker exec`), and measurements write to an untracked scratch path. The
   agents' roles override older examples it copies (the builder never commits or closes an issue).
   Then it commits the records. A work order nobody has started it may revise
   (`/triage revise work-order-NNNNNN …`).
2. `/implement <work order>`: the engineer builds, has the advisor and then the reviewer check it,
   writes `Report back, round N` into the work order (starting with `Started from: <sha>`, the commit
   it began from: `Base` is only the state at triage), and calls the **auditor** with only the work
   order's path. A work order it cannot build as written gets a `stopped: work-order defect` report
   instead, and goes to the auditor at once; one that would do harm goes to the user; a doubtful one
   is followed literally, with the question in the report.
3. The auditor (inside step 2, or by hand with `/audit <work order>`) runs the PASS CHECKLIST
   itself, checks the diff from `Started from` against the scope and every included issue's
   acceptance criteria, and rules on the builder's questions.
   - **Accepted:** a review round with the results; the work order and the items it fully covered
     move to `resolved/`; each nit left unfixed becomes a new issue; the index is updated; and it
     **commits**, by explicit path: the work, then the records (the new issues among them).
   - **Returned:** a review round with numbered blocker and nit findings, rulings and any
     amendments, nothing committed. The engineer fixes the findings and calls it again, without
     stopping.
   - **Amended** (answering a stopped report): each claimed defect ruled amended or stands; the
     engineer builds from the amended work order.
   - **Needs your decision:** a criterion that was never checked or that the work order forbade
     checking, a check needing a model run or restart, a second stop, or a fourth return. The
     engineer stops and asks the user; the answer goes into `/audit <work order> <decision>`.
   New defects outside the scope become new issues too, so a later `/triage` can fold them and
   the nits into work orders.
4. `/implement issue-NNNNNN` skips triage for one issue: the issue is the record (its criteria are
   the checklist, reports and reviews go into it), the auditor audits it the same way, and a wrong
   issue goes to the user rather than to an amendment. An issue in an open work order is refused.

## Why it is built this way

- **Batches.** Each delegation swaps the engineer's model out and mellum in, and back. The slot
  cache restores the engineer's processed conversation after a swap (measured on groot: ~9 s
  instead of re-reading ~51K tokens; it matters more on inkling, which reads ~90 tokens/s), but every
  swap is still a load each way, and only one conversation per model survives a swap. Subagents
  sharing a model in one batch take turns in a single slot without re-reading: llama.cpp's RAM
  prompt cache (`--cache-ram`) keeps each one's prompt (measured on mellum: 21 tokens re-processed
  instead of 19K). One batch per stage means one wake-up instead of one per task.
- **One model per message.** Mixing models in one message swaps between requests. Coder + scout
  share mellum; vision goes alone; advisor and reviewer share nail-qwen but are called one at a
  time. Two differently named models.ini entries swap even with the same weights, so agents that
  share a model use the identical entry name.
- **The engineer's model differs from every subagent's**; the batching rules assume each
  subagent call is a swap away from it.
- **Coders write the bulk of the code, even in one file; the engineer makes the surgical edits.**
  It kept failing to delegate. Under the first wording ("tiny edits" allowed, "code writing"
  delegated) groot made every fix itself, because the fixes were labels and records. The next rule
  (a single file, or fixes that build on each other, the engineer makes itself) still meant it never
  delegated: in the first work orders run
  (2026-11-26/27) every change was in one or two files, and the engineer, on inkling at 21 t/s
  decode, wrote everything itself through shell edits, with no coder or scout call at all. A
  batch costs two swaps; writing hundreds of lines at 21 t/s instead of mellum's 121 costs more.
  Delegation was then required for every change, with dependent work in a later batch.
- **Coders get the tasks with leverage, in small briefs.** Mellum (2.5B active) is fast but small. Its first real
  brief (2026-11-27) was one coder for three files, line numbers instead of text, and "read the
  work order first": in 12 minutes and ~39k output tokens it made two edits, one of which broke the
  file, spent turns on `execute` (sandboxed JavaScript, no `fs`), and reported the rest not done.
  A brief that spells out the code is no cheaper than the engineer writing it, so the split is by
  leverage: coders get tasks whose brief is much shorter than their output (new files and tests
  from an outline, a function from its behaviour, repeated changes); the engineer makes the
  surgical edits. A brief is one file and one task, self-contained, located by a quoted anchor, in
  behaviour rather than code. The coder searches with escaped regexes, reads each edit back and
  stops after two failed edits. Whether mellum then does well is unmeasured.
- **Advisor before reviewer, never together.** Reviewing code that does not yet meet the
  requirements is wasted, and its findings can conflict with the advisor's fixes. (Speed is not
  the reason: on one model both would keep their prompts, with the same two swaps.)
- **Advisor and reviewer only at the end**, never while planning or between batches: each call is
  a swap to a CPU-placed 35B. The cost is that a wrong plan is caught after the coders built on it;
  if the engineer often mis-plans, one advisor plan check before the first batch would cost one swap.
- **Advisor and reviewer run checks themselves.** Read-only, the advisor answered "can't verify"
  for every claim that needs a script's or test's output, exactly the claims an independent check
  matters most for. They run them without changing anything, and compare with the engineer's
  output; a difference is a finding.
- **Model-independent file access.** An advisor (qwen, later nail) reported existing files missing:
  paths relative to a folder the engineer had `cd`'d into, file search honouring `.gitignore`,
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
  other. Both, and the engineer, read untracked files (`git status`), since coders create files
  `git diff` does not show.
- **Coder has minimal tools.** mellum is a good coder but poor at agentic work, so the engineer
  explores, runs and verifies; the coder follows a brief and puts questions in its report.
- **Jobs that call cortex.** Any engineer turn is a request to its own model, so a turn while a
  script or test is sending requests to cortex swaps models under it. The engineer recognises
  such jobs (cortex URLs, `/v1/chat/completions`, an LLM client, a model setting; unknown = treat as
  one), runs them in one blocking call, and takes no turns or subagent calls until they end.
  Bot-marked scripts may be held up to `HUMAN_HOLD` (120 s) after its last request; that is expected.
- **Inkling as engineer** (inkling-2-mini 96k, the user's choice on 2026-11-27; groot before).
  Benched at 21 t/s decode and 90 t/s prefill, CPU-resident: a fresh session that reads ~50K tokens
  spends ~10 min reading, and the slot cache saves it from repeating that after each subagent swap.
  It differs from every subagent's model, which the batching rules assume. Its planning quality as
  engineer is unmeasured. groot (61 / 1453 t/s, GPU) was the previous choice: fastest
  large-context model, 1 of 2 right on a hard benchmark.
- **The engineer does not commit or push** unless asked or the documents require it; work orders are committed by the auditor.
- **Triage and audit are separate agents.** Triage is many-to-many (every open issue, grouping,
  ranking) and needs a fast large-context model: groot (61 / 1453 t/s, on the GPU, proven at tool
  use; 2026-11-27). Its hardest job is a complete work order with an exact checklist, which keeps
  the audit mostly mechanical. The audit is one work order in depth, on a model different from the
  builder (inkling) and the checkers (nail-qwen) so it does not share their blind spots:
  cyber-tiel-coder 128k (37.4 / 1161 t/s; the user's choice, 2026-11-27; its judgement unmeasured).
- **The auditor is a subagent the builder calls, and stays independent.** The engineer passes only
  the work order's path; the auditor treats anything else it is told as a claim, reads the record
  and the repository itself and runs the checks itself. Its verdict lives in the work order, not in
  the engineer's word: a work order without an accepted review round is not accepted. A subagent
  cannot ask the user, so decisions come back as `NEEDS YOUR DECISION` and the engineer stops.
  Calling it from the engineer makes one `/implement` run the whole build-audit-fix loop, and the
  auditor's commit leaves the next work order a clean start.
- **Both may run shell commands and commit tracker records by explicit path;** bulk `git add` /
  `commit` forms are denied so neither can sweep up other work. Only the auditor commits code, and
  only on acceptance, only the files in the scope diff.
- **Work-order records are append-only.** Builder reports and auditor reviews are added as numbered
  rounds and never edited; a wrong work order is corrected by an amendment in a review round. The
  history of what was asked, claimed and ruled stays readable, as the advisor's record rules expect.
- **A wrong work order is the auditor's to rule on, not the builder's.** The builder stops with
  evidence rather than building around a defect or editing the contract; the auditor rules with an
  amendment, which may correct the work order but never widen it or drop a criterion. A criterion the work order cannot check is settled by the user, because
  the fix (allow a model run, drop the criterion) is a decision, not a correction.
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

- The engineer sends changes to coders (look for `switch:` to mellum, and coder child sessions),
  and OpenCode runs a batch's subagent calls together (one switch per batch, not per task).
- Subagents get absolute paths (advisor sessions no longer open with `File not found` reads).
- mellum's tool calls work inside OpenCode.
- The `read` tool passes images to the vision model as images.
- `doom_loop: deny` stops a subagent that repeats a failing call, and after how many.
- `/implement` leaves the session on the engineer afterwards, or only that one message.
- A `/model` choice on the engineer persists across Tab switches.
- The RAM prompt cache keeps several conversations on nail-qwen as it does on mellum.
- The shell tool's maximum timeout (the cortex-job rule depends on it).
- The triage agent on groot: whether its work orders are complete enough for the builder, the
  grouping and ranking quality of `/triage`, whether it keeps to tracker records with the edit tool
  allowed, and whether its commits hold only its own files.
- The auditor on cyber-tiel: whether it catches a planted defect (a work order with a known missed
  check), whether it stays independent of what the engineer tells it, whether its commits hold only
  the scope's files, and whether the engineer really loops on `RETURNED` without stopping.

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
engineer marks hard or that failed verification after mellum) and **thinker** (a decision on a
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
