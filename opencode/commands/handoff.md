---
description: Write or update a handoff document so the work can be continued in a new session (optional: topic or path)
---

Write or update a handoff document for the work in this session, so that a new session with none of this conversation can continue it. Topic or path given by the user, if any: $ARGUMENTS

Where:
- If a handoff document for this topic already exists, update it in place; do not start a second one. Search the project's planning and docs folders for it.
- Otherwise put it in the project's `docs/sessions/` folder if it has one, named `YYYY-MM-DD-handoff-<topic>.md`; else where the project keeps planning documents (an existing folder such as `docs/`, `plans/` or `notes/`), named `handoff-<topic>.md`. If the project has no such folder, ask the user where it should go.

Contents, in this order:
1. **Title, Started, Last updated (today's date), Status:** one line on where the work stands, and anything the user asked you not to do yet.
2. **Goal:** the user's intent in their own terms, including constraints and preferences they stated. Quote them where the wording matters.
3. **Where things are:** every file, folder, service or setting involved, with one line each.
4. **Design and why:** each decision with the reason for it. Say where a reason or number came from (measured, documented, the user's judgement), and mark anything unmeasured as unmeasured.
5. **Verified:** facts that were checked, and how.
6. **Unverified:** assumptions and open questions, each with how to check it.
7. **Open items:** what is not done, marked where the user must decide first.
8. **Change log:** dated entries for every change made, including changes outside the project.

Rules:
- Write facts from this session's files, commands and the user's words, not from memory or guesses. Read the files you describe.
- When updating, keep what is still true, correct what changed, move finished open items into the change log, and update "Last updated".
- No secrets, credentials or personal details.
- Do not commit; tell the user the path when done.
