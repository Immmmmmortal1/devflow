---
name: bug-workflow
description: Plan-first path for bug fixes in dev-flow. Use bugkb, gstack-investigate, and gstack-review before any edit. Treat bug+feature requests as bug first. Pair with zentao-bug-gate when ZenTao id is required.
---

# Bug Workflow

## When

User report is **bug fix**: broken, unexpected, regressed, wrong behavior, crash.

If bug + feature mixed → **bug first**; defer expansion until root cause is confirmed.

## Order

1. Read `code-grounded` and fill classification + evidence.
2. **`bugkb`** — similar cases, root-cause patterns, regression hints.
3. **ZenTao bug id** — if `zentao-bug-gate` active and id missing → **stop**.
4. **`gstack-investigate`** — evidence-based root cause.
5. **Red-capable feedback loop** — before proposing a fix, establish a repro that
   **fails (red)** on the user's reported symptom using an allowed evidence type.
   Read [references/bug-repro-template.md](references/bug-repro-template.md) for
   the full contract (minimal repro, full scenario, allowed evidence, blocked
   handling). **Hard stop**: if no red-capable loop can be established → return
   `blocked`; do not propose a fix.
6. **`gstack-review`** — minimal fix plan, side effects, validation, comment locations.
7. Read **`confirm-gate`** → stop for user confirmation. Confirm-gate **hard-stops**
   if bugkb/investigate/review steps were skipped or the red-capable feedback loop
   is missing (see that skill).
8. After user confirms → implement confirmed scope only.
9. After fix → re-run the **minimal repro** (must pass green) and the **full
   scenario** (must pass green). Record both results; see bug-repro-template.
10. Read **`commit-gate`** (+ **`zentao-bug-gate`** if active).

## Plan must include

- Root cause tied to code/runtime evidence
- **Red-capable feedback loop**: minimal repro steps, red evidence, allowed type
  (unit-test / script / debugbridge-ui / debugbridge-log)
- Why the fix addresses root cause (not symptom only)
- Validation path: re-run minimal repro + full scenario after fix
- Where to add short comments at decision points

## Hard rules

1. Do not edit code during steps 1–7.
2. Do not skip bugkb → investigate → **red-capable loop** → review.
3. Do not guess root cause without investigation output.
4. Do not propose a fix when the red-capable feedback loop is missing or blocked.
5. Do not commit without re-running minimal repro and full scenario after the fix.
