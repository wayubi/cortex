# Work-order workflow: triage, engineer, auditor

How to take issues from `tracker/issues/open/` to finished, committed work with the OpenCode agents.
The design behind it is in `opencode-agents.md`; the tracker rules are in `AGENTS.md` ("Docs and
tracker").

## Before you start

- **Issues to work on.** Triage works from `tracker/issues/open/`, written from
  `tracker/issues/TEMPLATE.md`. Write them yourself or ask any agent to.
- **Where to run it.** OpenCode, started in the project's folder: in the `opencode` container,
  `docker exec -it cortex-opencode-1 bash`, then `cd` to the project and run `opencode`. A paired app
  works too, opened on the project's folder.
- **A clean tree.** Commit or set aside your own changes first (`git status`). The agents commit only
  their own files, and stop rather than commit a file that already held your change.
- **Who runs where:**

  | Agent | Kind | Model | Job |
  |---|---|---|---|
  | triage | primary, `/triage` | groot (GPU, fast) | writes, groups and ranks work orders |
  | engineer | primary, `/engineer` | inkling (slow reader: minutes before it starts) | plans, briefs coders, checks, loops with the auditor |
  | coder, scout | subagents | mellum | make the changes; search |
  | advisor, reviewer | subagents | nail-qwen | check against the documents; check the code |
  | auditor | subagent, or `/audit` | cyber-tiel-coder | audits the work order; commits accepted work |

## Steps

### 1. Triage

1. `/new`, then `/triage`. To limit it: `/triage issue-000003 issue-000007`; plans only when named:
   `/triage plan-000012`.
2. It proposes, and writes nothing yet: each work order (what it includes and why), the ranking with
   predecessors, and the issues it left out with the reason (needs a decision, lacks evidence, should
   be closed). It also names any issue criterion a work order could not check without your approval
   (a model run, a bench, a restart).
3. Approve, or amend ("split the second one", "leave issue 7 out", "allow the barak6 run").
4. It writes the work orders to `tracker/work-orders/open/`, adds back-links to the issues, updates
   `tracker/work-orders/triage.md`, and **commits** them. Its report names the commit.

### 2. Engineer

1. `/new`, then `/engineer work-order-NNNNNN`: the top-ranked one in `triage.md` whose predecessors
   are resolved.
2. Leave it to run. It goes through, on its own:
   - reading the work order and the code (minutes, on inkling);
   - **coder batches** on mellum, one coder per file; dependent work in a later batch;
   - its own quick checks, then the **advisor** until it passes, then the **reviewer**;
   - writing `Report back, round N` into the work order;
   - the **auditor**, which reads the work order and the repository itself and runs the PASS
     CHECKLIST.
   - **Returned:** the engineer fixes the findings and calls the auditor again, without stopping.
   - **Stopped** (the work order cannot be built as written): the auditor rules on each defect, and
     the engineer builds from the amended work order.
3. Don't type into the session while it runs a job that calls cortex (a script, a test suite, a
   model run): each message you send swaps models under the job.
4. It ends with one of these:
   - **Accepted.** The auditor has moved the work order and the issues it covered to `resolved/`,
     updated `triage.md`, and **committed** twice: the work, then the records. Check with
     `git log --oneline -3` and `git status`, then push when you're ready.
   - **Needs your decision.** It says what to decide: a criterion the work order cannot check, a
     check that needs a restart or a model run, a second stop, or a fourth return. Answer with
     `/audit work-order-NNNNNN <your decision>` (for example `approved: run C5`, or
     `drop criterion 3`). If the audit then returns the work, run `/engineer work-order-NNNNNN` in
     a new session.
   - **Stopped before the audit.** The advisor did not pass after three rounds, or the work order
     would do harm. Read its open findings and decide: answer it in the session, or change the work
     order through `/triage`.

### 3. Next

Take the next work order in `triage.md`. Run `/triage` again when new issues arrive; it re-ranks
everything still open.

## Good to know

- **Commits.** Triage commits the work orders it wrote; the auditor commits accepted work and its
  records. Both commit by explicit path, leave any other uncommitted file alone and list it in their
  report. Nothing is pushed: that is yours.
- **`/audit work-order-NNNNNN`** runs the auditor by hand, for work done outside `/engineer`.
- **Watching it:** `docker logs -f cortex-openresty-1 | grep '\[lua\]'` shows each model switch
  (`switch:` to mellum means coders are working; to cyber-tiel, the audit).
- **Problems outside the work order** become new issues, never extra work in the work order; the
  next `/triage` picks them up.
- **Why fresh sessions:** a builder that needs earlier chat shows the work order is incomplete, and
  switching agents in one session sends its whole history to the other model.
