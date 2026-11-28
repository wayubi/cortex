# Work-order workflow: triage, engineer, auditor

How to take issues from `tracker/issues/open/` to finished, accepted work with the OpenCode agents.
The design behind it is in `opencode-agents.md`; the tracker rules are in `AGENTS.md` ("Docs and
tracker").

## Before you start

- **Issues to work on.** The triage agent triages what is in `tracker/issues/open/`, written from
  `tracker/issues/TEMPLATE.md`. Write them yourself or ask any agent to.
- **Where to run it.** OpenCode, started in the project's folder: in the `opencode` container,
  `docker exec -it cortex-opencode-1 bash`, then `cd` to the project and run `opencode`. A paired app
  works too, opened on the project's folder.
- **Models.** The triage agent runs on groot (on the GPU, fast); the engineer on inkling, which reads
  slowly, so a fresh `/engineer` session spends minutes reading before it starts; the auditor, a
  subagent the engineer calls, on cyber-tiel-coder.

## The cycle

Two steps, each in a **fresh session** (`/new`). The work order file is the hand-off between them.

1. **Triage.** `/new`, then `/triage`, or name what to triage: `/triage issue-000003 issue-000007`,
   or plans with `/triage plan-000012`.
   - It proposes the work orders (what each includes and why), the ranking, and the issues it left
     out with reasons. It writes nothing yet.
   - Approve, or amend ("split the second one", "leave issue 7 out").
   - On approval it writes the work orders to `tracker/work-orders/open/`, adds back-links to the
     issues, updates `tracker/work-orders/triage.md`, and **commits** those files.
2. **Engineer.** `/new`, then `/engineer work-order-000001` (the top-ranked one in `triage.md`).
   It runs to the end on its own:
   - builds it, has the advisor and then the reviewer check it, and appends `Report back, round N`
     to the work order;
   - calls the **auditor**, which runs the PASS CHECKLIST itself and checks the diff and every
     issue's acceptance criteria;
   - **returned:** the engineer fixes the findings and calls the auditor again, without stopping;
   - **stopped** (the work order cannot be built as written): the auditor rules on each defect and
     the engineer builds from the amended work order;
   - **accepted:** the auditor moves the work order and the issues it covered to `resolved/`,
     updates `triage.md`, and **commits** the work and then the records. Nothing is pushed.
   - **Needs your decision:** a criterion the work order cannot check (for example it needs a model
     run the work order forbids), a check that needs a restart or a model run, a second stop, or a
     fourth return. The engineer stops and tells you what to decide. Answer with
     `/audit work-order-000001 <your decision>` (for example `approved: run C5`), in the same or a
     new session; if it returns the work, run `/engineer work-order-000001` again.
3. **Next.** Take the next work order in `triage.md`. Run `/triage` again when new issues arrive; it
   re-ranks everything still open.

## Good to know

- **Commits.** Triage commits the work orders it wrote; the auditor commits accepted work and its
  records. Both commit by explicit path and leave any other uncommitted file alone, listed in their
  report. Pushing is yours.
- **`/audit work-order-N`** runs the auditor by hand, for work done outside `/engineer`.
- **Problems outside the work order** become new issues, never extra work in the work order; the
  next `/triage` picks them up.
- **Why fresh sessions:** a builder that needs earlier chat shows the work order is incomplete, and
  switching agents in one session sends its whole history to the other model.
