<!-- Copy to tracker/work-orders/open/work-order-NNNNNN-short-slug.md (next ID: one above the
highest in open/, resolved/ and closed/). A work order organises one or more plans and/or issues
into one actionable unit for an agent. It must be complete: the agent needs nothing that is not
written here. Delete this comment. No personal names, hostnames, IPs or private paths: this
repository is public. -->

# work-order-NNNNNN: <short title>

**Base:** commit `<sha>` (the state the work starts from)
**Date:** YYYY-MM-DD
**Status:** open
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

## 4. Report back

<What the agent reports when done: commits, test output, measurements, questions.>

## Review

<Filled in by the reviewer: checklist results, rulings on questions, the decision. On resolve,
move the included items it fully covered to resolved/ in the same commit.>
