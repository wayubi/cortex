<!-- Copy to tracker/work-orders/open/work-order-NNNNNN-short-slug.md (next ID: one above the
highest in open/, resolved/ and closed/). A work order organises one or more plans and/or issues
into one actionable unit for an agent. It must be complete: the agent needs nothing that is not
written here. Delete this comment. No personal names, hostnames, IPs or private paths: this
repository is public. -->

# work-order-NNNNNN: <short title>

**Base:** commit `<sha>` (the state the work starts from)
**Date:** YYYY-MM-DD
**Status:** open
<!-- open | open (returned, round N) | resolved YYYY-MM-DD | closed YYYY-MM-DD. Rank: the triage index. -->
**Author:** <who wrote it>
**Includes:** <issue-NNNNNN, plan-NNNNNN, ...> (each gets `**Work order:** work-order-NNNNNN`)
**Predecessors:** <optional: earlier work orders this builds on>

---

## READ THIS FIRST

<The rules for the agent doing the work: what it must not touch or run (GPU, benches, restarts,
commits), what to do when a rule seems wrong (write the question in the report and follow the most
literal reading).>

## 1. What to build

<Each step, in order, with the files and functions it changes. Frozen: the agent does not widen it.>

## 2. Tests

<The tests or checks to add or run, by name.>

## 3. PASS CHECKLIST

<Numbered boxes the reviewer checks, each with the command that checks it and its expected output.
If every box passes, the work is accepted.>

- [ ] C1:

## Report back, round 1 (YYYY-MM-DD)

<Written by the builder, never edited afterwards: commits, test and checklist output, measurements,
answers to every finding of the latest review round, questions. Each later round adds its own
section.>

## Review, round 1 (accepted|returned, YYYY-MM-DD)

<Written by the foreman (/accept), never edited afterwards: each checklist item with its result;
numbered findings, each a **blocker** or a **nit**, with evidence; rulings on the builder's
questions; amendments, if the work order was wrong. Accepted: the commits, and the included items it
fully covered move to resolved/ in the same change. Round 3 returned is the last; after that the
foreman asks the user.>
