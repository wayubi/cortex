# Fix: MTP Settings Don't Actually Inherit From Parent to Sibling Models

**Date:** 2026-09-10
**Status:** Plan only — not yet implemented.

## Context

`inherit_json()` (tools/bench.sh) is what lets a sibling model (same GGUF + effective ctx-size
as a parent, e.g. a `-coder` variant) skip its own expensive `bisect`/`mtp` discovery and instead
copy the parent's validated results. `batch-size`/`ubatch-size` propagate correctly today via
`set_batch_for()`, which inserts the keys into the child's ini section if they're missing.
`spec-type` / `spec-draft-n-max` / `spec-draft-p-min` (the MTP config) do **not** — even though
the code clearly intends them to (comment: "Write parent's MTP values ... to child's models.ini
section", log line: `"Inherited parent MTP config: ..."`).

### Why, exactly (verified live, not just read)

Confirmed against a real run (`logs/bench_20260910-1940.log`): the parent
`deepseek-v4-pro-qwen3.5-9b-q4-mtp-128k-think` benched successfully end-to-end
(`mtpcheck`/`bisect`/`mtp`/`bench` all `OK`, `mtp.tuning_status` in its JSON is `"ok"`). The
sibling `deepseek-v4-pro-qwen3.5-9b-q4-mtp-128k-think-coder` correctly took the inherit path and
the log printed `"Inherited parent MTP config: spec-draft-n-max=2 spec-draft-p-min=0.7"`. But the
child's actual `models.ini` section (checked immediately after) has **no** `spec-type`,
`spec-draft-n-max`, or `spec-draft-p-min` line at all. Three compounding bugs in
`inherit_json()` (tools/bench.sh:385–498, current line numbers as of this review):

1. **`spec-type` is never propagated at all.** The function only ever touches
   `spec-draft-n-max`/`spec-draft-p-min` (lines 476–491). It assumes the child already has
   `spec-type=draft-mtp` set some other way (e.g. a prior `mtpcheck` run on that exact model).
   A freshly-added sibling that was never individually `mtpcheck`'d — the normal case for a
   model meant to just inherit — has no `spec-type` line, so it silently stays a non-MTP model
   no matter what `n_max`/`p_min` say.

2. **The `n_max`/`p_min` writer only replaces existing lines, with no insert fallback**
   (lines 483–489):
   ```python
   for line in sec.split('\n'):
       if re.match(r'\s*spec-draft-n-max\s*=', line) and nmax:
           new_lines.append('spec-draft-n-max = ' + nmax)
       elif re.match(r'\s*spec-draft-p-min\s*=', line) and pmin:
           new_lines.append('spec-draft-p-min = ' + pmin)
       else:
           new_lines.append(line)
   ```
   Unlike `set_batch_for()` (tools/bench.sh:346–382), which explicitly inserts `batch-size`/
   `ubatch-size` after the first key line when they're absent, this loop has no `if not found:
   insert` branch. A child section with zero `spec-draft-*` lines to begin with gets nothing
   written — the loop just passes every line through unchanged.

3. **The success log fires unconditionally** (line 492), regardless of whether the python call
   above actually found anything to replace. This is what produced the false-positive log message
   — it reports success even when, per bug 2, nothing was written.

### Scope of impact

Any sibling of an MTP-tuned parent that doesn't *already* have `spec-type=draft-mtp` set in its
own ini section before inheritance runs. Since `family_of()` matches purely on `hf` + effective
`ctx-size`, a sibling shares the exact same GGUF as its parent — MTP capability is identical by
construction, so there is no correctness reason to withhold `spec-type` propagation; it was
simply never implemented, only the tuning values were (assuming `spec-type` was already there).

Consequence when this fires: the sibling's **JSON record** (copied wholesale from the parent)
shows `mtp.n_max`/`p_min`/`drafter=in-model` as if MTP is active, while its **live `models.ini`
config** has no `spec-type` — so if that model is ever actually served, it silently runs without
MTP acceleration, contradicting its own benchmark record.

## Fix

### 1. Add a generic `set_key_for(SECTION, KEY, VALUE)` helper

Place it next to `set_batch_for()` (tools/bench.sh, after line 382). Same insert-or-replace
body as `set_key()` (tools/bench.sh:200–230) but parameterized on section instead of assuming
the global `$MODEL` — `set_key()` can't be reused directly here because `inherit_json` needs to
write into `$CHILD`'s section while the global `$MODEL` may be set to something else at that
point in the call graph (this is exactly the awkwardness the now-reverted CPU-MoE work had to
route around with a temporary `$MODEL` swap — a real reusable helper is cleaner and avoids that
pattern recurring):

```bash
set_key_for() {
  local SECTION=$1 KEY=$2 VALUE=$3
  python3 -c "
import re, sys
section='$SECTION'; key='$KEY'; value='$VALUE'; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(section)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR: section not found'); sys.exit(1)
section_text = m.group(2)
new_lines = []
found = False
for line in section_text.split('\n'):
    if re.match(r'\s*'+re.escape(key)+r'\s*=', line):
        prefix = line.split('=')[0] + '='
        new_lines.append(prefix + ' ' + value)
        found = True
    else:
        new_lines.append(line)
if not found:
    keys = [l.split('=')[0].strip() for l in section_text.split('\n') if '=' in l and not l.strip().startswith(('#',';'))]
    max_len = max((len(k) for k in keys), default=len(key))
    pad = max_len - len(key) + 1
    new_lines.insert(1, key + ' ' * pad + '= ' + value)
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + '\n'.join(new_lines) + content[m.end(2):])
print('written')
"
}
```

Note this mirrors `set_key()` almost exactly (that's deliberate — same alignment/insert
behavior other keys already get), just taking the section as an argument. `set_key()` itself is
left untouched; nothing about the CPU-MoE revert needs to be un-reverted for this.

### 2. In `inherit_json()`, replace the whole `if [ "$PARENT_TUNING" = "ok" ]` block

(tools/bench.sh:458–491) with:

```bash
  if [ "$PARENT_TUNING" = "ok" ]; then
    local PARENT_SPEC_TYPE PARENT_NMAX PARENT_PMIN
    PARENT_SPEC_TYPE=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
v = re.search(r'spec-type\s*=\s*(\S+)', sec)
print(v.group(1) if v else '')
")
    PARENT_NMAX=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
v = re.search(r'spec-draft-n-max\s*=\s*(\S+)', sec)
print(v.group(1) if v else '')
")
    PARENT_PMIN=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
v = re.search(r'spec-draft-p-min\s*=\s*(\S+)', sec)
print(v.group(1) if v else '')
")
    if [ -n "$PARENT_SPEC_TYPE" ] && [ -n "$PARENT_NMAX" ] && [ -n "$PARENT_PMIN" ]; then
      set_key_for "$CHILD" spec-type "$PARENT_SPEC_TYPE"
      set_key_for "$CHILD" spec-draft-n-max "$PARENT_NMAX"
      set_key_for "$CHILD" spec-draft-p-min "$PARENT_PMIN"
      log "  Inherited parent MTP config: spec-type=$PARENT_SPEC_TYPE spec-draft-n-max=$PARENT_NMAX spec-draft-p-min=$PARENT_PMIN"
    else
      log "  MTP values NOT inherited (parent tuning_status=ok but spec-type/n-max/p-min incomplete in parent section — inspect $PARENT's ini entry)"
    fi
  elif [ "$PARENT_TUNING" = "unknown" ]; then
    log "  MTP values NOT inherited (parent JSON predates tuning_status; re-run 'bench.sh mtp $PARENT' to stamp it)"
  else
    log "  MTP values NOT inherited (parent tuning_status=$PARENT_TUNING)"
  fi
```

This fixes all three bugs at once: `spec-type` now propagates; `set_key_for` inserts when the
key is missing (fixing the silent no-op); and the success log only fires after the writes,
gated on all three parent values actually being present (fixing the false positive) — a
`tuning_status=="ok"` parent should always have `spec-type=draft-mtp` set (that's a precondition
for `cmd_mtp` to have run at all), so the `else` branch is a defensive belt-and-suspenders case,
not an expected path.

## What NOT to change

- The `PARENT_TUNING == "ok"` gate itself (don't propagate from an unvalidated/failed/stale
  parent tune) — that part is correct and intentional, keep it exactly as-is.
- `set_key()` and `set_batch_for()` — untouched, `set_key_for()` is additive.
- Nothing about `cmd_mtp`, `mtpcheck`, or the parent's own tuning logic — this bug is entirely
  in the propagation step, not in how a parent gets tuned.

## Verification

This is testable without a fresh expensive bench run, because the deepseek parent already has a
`tuning_status: "ok"` JSON on disk from the run that exposed the bug:

1. `bash -n tools/bench.sh` after the edit.
2. Directly call `inherit_json deepseek-v4-pro-qwen3.5-9b-q4-mtp-128k-think
   deepseek-v4-pro-qwen3.5-9b-q4-mtp-128k-think-coder` (source the functions the same way this
   session's live tests did — truncate the file before `# ── MAIN` and source it, or invoke via
   the real dispatcher's inherit path) and confirm the child's `models.ini` section now has
   `spec-type = draft-mtp`, `spec-draft-n-max = 2`, `spec-draft-p-min = 0.7`.
3. Regression check: run the same call for an existing family that already has correctly
   populated MTP keys in a sibling section (if the pre-fix inheritance run for `-think`/its
   child from *before* this bug was noticed left any consistent example — otherwise pick any two
   MTP siblings and hand-set matching keys first) and confirm the values are unchanged
   (idempotent replace, not duplicated lines).
4. Confirm `set_key_for`'s insert path aligns the `=` column consistently with the rest of the
   section (same visual convention `set_key`/`set_batch_for` already produce elsewhere) — eyeball
   the child section after the test.
5. Re-run `gen_metrics.sh` and spot-check that the child's row in `full-metrics.md` (`n_max`/
   `p_min`/`drafter` columns) still matches its JSON record, which was already correct before
   this fix — only the live ini config was wrong, so this should show no change.
