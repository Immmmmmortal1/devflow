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
5. **`gstack-review`** — minimal fix plan, side effects, validation, comment locations.
6. Read **`confirm-gate`** → stop for user confirmation. Confirm-gate **hard-stops** if bugkb/investigate/review steps were skipped (see that skill).
7. After user confirms → implement confirmed scope only.
8. Read **`commit-gate`** (+ **`zentao-bug-gate`** if active).

## Plan must include

- Root cause tied to code/runtime evidence
- Why the fix addresses root cause (not symptom only)
- Validation / repro path
- Where to add short comments at decision points

## Hard rules

1. Do not edit code during steps 1–6.
2. Do not skip bugkb → investigate → review.
3. Do not guess root cause without investigation output.
