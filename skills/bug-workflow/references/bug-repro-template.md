# Bug Repro Template (Red-Capable Feedback Loop)

Read this reference when `bug-workflow` Step 5 activates. It defines the red-capable
feedback loop contract: a repro that can **fail** (red) when the bug is present and
**pass** (green) after the fix. Without a red-capable loop the fix cannot be
verified.

## Purpose

Before proposing a fix, the agent must establish a feedback loop that precisely
captures the user's reported symptom. "Precisely" means the loop fails on the
symptom, not on an unrelated error or a guessed cause. If no such loop can be
built, the bug is **blocked** — do not propose a fix.

## Allowed evidence types

A red-capable feedback loop may use one or more of:

| Type | Red signal | Green signal | When to use |
|-----|-----------|---------------|-------------|
| **Unit / integration test** | assertion fails on current code | assertion passes after fix | logic is testable in isolation |
| **Script / CLI** | exit code non-zero or expected output mismatch | exit code 0 or output matches | behavior is observable via shell |
| **DebugBridge action + UI tree** | expected page/element/anchor absent or wrong state | expected page/element/anchor present with correct state | UI/runtime behavior visible via DebugBridge |
| **DebugBridge + current-run App log** | expected log marker absent or error log present | expected marker present, error log absent | runtime behavior observable through in-memory log pool |

Screenshots are **not** evidence for this loop. Only DebugBridge UI tree / runtime
node / log evidence counts as runtime evidence (consistent with the global rule).

## Minimal repro

The minimal repro is the smallest action sequence that triggers the symptom. It
must:

- reference the exact user-reported symptom (crash, wrong value, missing element,
  unexpected navigation, etc.);
- use only the evidence types listed above;
- produce a **red** result on the unmodified codebase.

```text
Symptom:
Repro type: unit-test | script | debugbridge-ui | debugbridge-log
Minimal repro steps:
  1. action / test case / script command
  2. action / test case / script command
Expected (green):
Actual (red):
Red evidence: test assertion / exit code / DebugBridge page+anchor / log marker
```

## Full scenario

After the fix, re-run **both** the minimal repro and the full scenario. The full
scenario covers the broader user workflow around the symptom to catch regressions.

```text
Full scenario steps:
  1. user workflow step
  2. user workflow step
Expected (green):
Re-run minimal repro: pass | fail
Re-run full scenario: pass | fail
Green evidence: test assertion / exit code / DebugBridge page+anchor / log marker
```

## Blocked: cannot establish red-capable loop

If no allowed evidence type can produce a red signal on the symptom, the bug is
**blocked**. Record:

```text
Blocked reason: cannot establish red-capable feedback loop
Attempted types: unit-test | script | debugbridge-ui | debugbridge-log
Why each failed:
  - type: reason
Next safe action: investigate alternative evidence or escalate to human
```

Do not propose a fix when blocked. Return to `bug-workflow` Step 4
(`gstack-investigate`) or escalate.

## Relationship to confirm-gate and commit-gate

- **confirm-gate**: the bug plan must include the minimal repro and its red
  evidence. A plan without a red-capable loop is incomplete — confirm-gate hard
  stops.
- **commit-gate**: the commit summary must report the re-run results of both the
  minimal repro and the full scenario. A commit without re-run evidence is a hard
  stop.
