# Work-order workflow: using the foreman

How to take issues from `tracker/issues/open/` to finished, accepted work with the OpenCode agents.
The design behind it is in `opencode-agents.md`; the tracker rules are in `AGENTS.md` ("Docs and
tracker").

## Before you start

- **Issues to work on.** The foreman triages what is in `tracker/issues/open/`, written from
  `tracker/issues/TEMPLATE.md`. Write them yourself or ask any agent to.
- **Where to run it.** OpenCode, started in the project's folder: in the `opencode` container,
  `docker exec -it cortex-opencode-1 bash`, then `cd` to the project and run `opencode`. A paired app
  works too, opened on the project's folder.
- **Models.** The foreman runs on groot (on the GPU, fast); the orchestrator on inkling, which reads
  slowly, so a fresh `/orchestrate` session spends minutes reading before it starts.

## The cycle

Every step starts in a **fresh session** (`/new`). The work order file is the hand-off between them.

1. **Triage.** `/new`, then `/triage`, or name what to triage: `/triage issue-000003 issue-000007`,
   or plans with `/triage plan-000012`.
   - It proposes the work orders (what each includes and why), the ranking, and the issues it left
     out with reasons. It writes nothing yet.
   - Approve, or amend ("split the second one", "leave issue 7 out").
   - On approval it writes the work orders to `tracker/work-orders/open/`, adds back-links to the
     issues, updates `tracker/work-orders/triage.md`, and **commits** those files.
2. **Build.** `/new`, then `/orchestrate work-order-000001` (the top-ranked one in `triage.md`).
   - The orchestrator builds it, has the advisor and reviewer check it, and appends
     `Report back, round 1` to the work order.
   - **Commit** the work and the report, unless the work order told the builder to commit. The
     foreman will not review uncommitted work.
   - **Stopped:** if the work order cannot be built as written, the orchestrator builds nothing and
     writes `Report back, round 1 (stopped: work-order defect)`. Commit it and go to step 3: the
     foreman rules on each defect (`AMENDED (round 1)`) and you build again.
3. **Accept.** `/new`, then `/accept work-order-000001`. Never in the builder's session.
   - It runs the PASS CHECKLIST itself and checks the diff and every issue's acceptance criteria.
     Its first line is `ACCEPTED`, `RETURNED (round N)`, `AMENDED (round N)` or
     `NEEDS YOUR DECISION`. It commits its own records each time.
   - **Accepted:** the work order and the issues it covered move to `resolved/`, and `triage.md` is
     updated.
   - **Returned:** a `Review, round N` section lists blockers, nits, rulings and any amendments.
     Repeat step 2 (`/new`, `/orchestrate work-order-000001`); the orchestrator reads the review from
     the file.
   - **Needs your decision:** an issue criterion the work order cannot check (for example it needs a
     model run the work order forbids), a second stopped report, or a fourth return. Nothing is
     written; answer, and run `/accept` again.
4. **Next.** Take the next work order in `triage.md`. Run `/triage` again when new issues arrive; it
   re-ranks everything still open.

## Good to know

- **Commits.** The foreman commits the tracker records it wrote, by explicit path, and lists any
  other uncommitted files without touching them. You commit the builder's work. Each step then
  starts from a clean `Base`, and the history shows what each agent wrote.
- **The foreman asks before some checks:** any checklist command that restarts a service, loads or
  benches models, or deploys anything.
- **Problems outside the work order** become new issues, never extra work in the work order; the
  next `/triage` picks them up.
- **Why fresh sessions:** the foreman judges the record and the repository, not the builder's
  conversation; a builder that needs earlier chat shows the work order is incomplete; and switching
  agents in one session sends its whole history to the other model.
