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
- **Speed.** The foreman runs on the checkers' model (the 35B the advisor and reviewer use), partly
  on the CPU, so it is slower than the orchestrator.

## The cycle

Every step starts in a **fresh session** (`/new`). The work order file is the hand-off between them.

1. **Triage.** `/new`, then `/triage`, or name what to triage: `/triage issue-000003 issue-000007`,
   or plans with `/triage plan-000012`.
   - It proposes the work orders (what each includes and why), the ranking, and the issues it left
     out with reasons. It writes nothing yet.
   - Approve, or amend ("split the second one", "leave issue 7 out").
   - On approval it writes the work orders to `tracker/work-orders/open/`, adds back-links to the
     issues, and updates `tracker/work-orders/triage.md`.
   - **Commit.**
2. **Build.** `/new`, then `/orchestrate work-order-000001` (the top-ranked one in `triage.md`).
   - The orchestrator builds it, has the advisor and reviewer check it, and appends
     `Report back, round 1` to the work order.
   - **Commit** the work and the report.
3. **Accept.** `/new`, then `/accept work-order-000001`. Never in the builder's session.
   - It runs the PASS CHECKLIST itself and checks the diff and every issue's acceptance criteria.
     Its first line is `ACCEPTED` or `RETURNED (round N)`.
   - **Accepted:** the work order and the issues it covered move to `resolved/`, and `triage.md` is
     updated. **Commit.**
   - **Returned:** a `Review, round N` section lists blockers, nits, rulings and any amendments.
     **Commit**, then repeat step 2 (`/new`, `/orchestrate work-order-000001`); the orchestrator reads
     the review from the file.
   - **After three returns** the foreman stops and asks you whether to split, narrow or close the
     work order.
4. **Next.** Take the next work order in `triage.md`. Run `/triage` again when new issues arrive; it
   re-ranks everything still open.

## Good to know

- **Commit between steps.** No agent commits. Each step then starts from a clean `Base`, and the
  history shows what each agent wrote.
- **The foreman asks before some checks:** any checklist command that restarts a service, loads or
  benches models, or deploys anything.
- **Problems outside the work order** become new issues, never extra work in the work order; the
  next `/triage` picks them up.
- **Why fresh sessions:** the foreman judges the record and the repository, not the builder's
  conversation; a builder that needs earlier chat shows the work order is incomplete; and switching
  agents in one session sends its whole history to the other model.
