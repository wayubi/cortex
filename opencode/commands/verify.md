---
description: Have the advisor check the current work against source documents (give paths to the spec, plan, work order, issues or reviews)
agent: advisor
subagent: true
---

Check the work in this repository against its source documents and report every requirement or finding as met, not met or can't verify, with evidence.

Source documents and focus named by the user (if none, find the governing documents yourself): $ARGUMENTS

The deliverable is the current state of the repository, including uncommitted changes. Run the commands a claim needs yourself (tests, scripts, reproductions), without changing anything; only if one is refused or needs something you do not have, name the exact command so it can be run and its output sent back to you.
