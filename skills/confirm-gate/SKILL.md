---
name: confirm-gate
description: Block all source edits until the user confirms a decision-ready plan. Read after analysis and before any implementation in dev-flow. Output the confirmation template; wait for explicit proceed.
---

# Confirm Gate

## Purpose

No code changes until the user confirms the plan.

## When

Run after analysis (`feature-workflow` or `bug-workflow`) and **before any file edit**.

## Output template

Separate **Facts** (agent-investigated, evidence-cited) from **Decisions**
(human trade-offs). Read
[references/facts-decisions-frontier.md](references/facts-decisions-frontier.md)
for the full contract (Facts, Decisions, decision frontier, frontier closure).
The decision frontier must be **closed** before the user can confirm.

```text
User asked for:
Type: feature | bug | ui_review-repair
In scope:
Out of scope:
Evidence read:
Analysis tool used:
bugkb findings:
ZenTao bug id: (required for bugs when zentao-bug-gate active; else n/a)
Root cause: (bugs only)
Red-capable feedback loop: (bugs only — minimal repro + red evidence; see bug-workflow references/bug-repro-template.md)
Facts:
  - fact statement | evidence: path/line, test, runtime node, log marker, artifact
Decisions:
  - decision: statement | options: A / B / ... | recommendation: ... | reason: ...
Decision frontier: closed | partially-open | blocked
  (frontier = decisions whose dependencies are all closed; only frontier decisions can be confirmed)
Task Graph: (feature only — when ≥2 independently verifiable slices or real deps/fog; see feature-workflow references/task-graph-template.md)
  - graph summary: slice count, dependency structure, fog items
  - frontier closure: all frontier slice open decisions answered
Files likely to change:
Plan:
Validation:
Sub-gates active: [none | zentao-bug-gate | ...]
Need user confirmation before coding: yes
```

When `api-contract` is active, also include:

```text
API contract source:
Endpoint contract:
Business mapping table:
Golden cases:
Unused fields:
Contract validation:
```

Do **not** output this template until step-completion checks below pass. If a check fails, finish the missing step first — do not ask the user to confirm an incomplete analysis.

## Step-completion checks (before template)

### All types

- `Evidence read` lists concrete paths (and line ranges when claiming code behavior)
- `Analysis tool used` names the skills/tools actually run this session — not planned steps
- If `api-contract` is active, the plan includes API contract source, endpoint contract, business mapping table, golden cases, unused fields, and contract validation.
- If `api-contract` is active, every consumed API field is mapped to a business state and UI/interaction owner, or explicitly listed under unused fields with a reason.

### Bug (`Type: bug`)

All must pass before outputting the template:

1. **`bugkb findings`** — not empty; not placeholders (`n/a`, `none`, `无`, `待查`, `TBD`). Must cite at least one concrete search outcome: similar bug id/title, pattern hit, or explicit "bugkb searched, no similar cases" with query/scope stated.
2. **`Analysis tool used`** — must include **`gstack-investigate`** (and **`gstack-review`**). If investigate is missing → run investigate first; do not confirm.
3. **`Root cause`** — tied to investigation evidence: file path + line range, log/stack trace, or repro step — not speculation.
4. **`Red-capable feedback loop`** — the plan must include a minimal repro that produces a **red** (fail) signal on the user's symptom using an allowed evidence type (unit-test / script / debugbridge-ui / debugbridge-log). If no red-capable loop can be established → the bug is **blocked**; do not output the template.

### Feature (`Type: feature`)

- **`Analysis tool used`** — must include **`gstack-review`**
- **`bugkb findings`** — leave `n/a (pre-implementation; runs after implementation per feature-workflow)` — do not run pre-implementation bugkb unless user asked
- **`Task Graph`** — when the task has ≥2 independently verifiable vertical slices or real dependencies/fog, the plan must include a Task Graph summary (slice count, dependency structure, fog items) and frontier closure status. See [feature-workflow references/task-graph-template.md](../feature-workflow/references/task-graph-template.md). When neither trigger condition is met, leave `n/a (single-slice; no deps/fog)`.
- **`Decision frontier`** — must be `closed`. If partially-open or blocked → do not output the template.

### UI review repair (`Type: ui_review-repair`)

Use this type only for the **first authorized source edit** in a `ui_review` session (see `ui-review`
Step 3). All must pass before outputting the template:

1. **`Analysis tool used`** — must include **`ui-review`** with a completed `parity-result.*`.
2. **`In scope`** — exactly `units_to_fix + runtime_extras_to_remove` from
   `parity-confirmed.json` (`wrong` / `missing` rows, authorized screen rows, or explicit runtime
   extras). No `ok` / `skip` / `defer` ids.
3. **`Evidence read`** — includes the parity artifact workspace and the code path(s) implementing the
   authorized units.
4. **`bugkb findings`** — `n/a (ui_review parity repair)` unless the human asked for a bugkb pass.
5. **`Files likely to change`** — limited to owners of the authorized units.

`ui_review-repair` does not require `gstack-review` or `gstack-investigate`; its analysis is the
`ui-review` parity result plus per-unit code-grounded evidence.

## Hard stop if

- `Evidence read` is empty but plan proposes concrete changes
- `In scope` includes work the user did not ask for
- **Bug:** any step-completion check above fails — **do not output the template**; complete the missing step
- **Bug:** `Root cause` present but lacks code/runtime evidence
- **Bug:** `Red-capable feedback loop` missing — no minimal repro with red signal established; the bug is blocked
- **Feature:** `Analysis tool used` omits `gstack-review`
- **Feature:** `Decision frontier` is `partially-open` or `blocked` — do not confirm until all frontier decisions are answered
- **Feature:** `Task Graph` required (≥2 slices or real deps/fog) but graph summary or frontier closure is missing
- **API work:** endpoint/field/API-driven behavior is involved but `api-contract` is missing from `Analysis tool used` or `Sub-gates active`
- **API work:** any consumed API field lacks business/UI mapping or golden-case validation
- **UI review repair:** `In scope` differs from `parity-confirmed.json`
  `units_to_fix + runtime_extras_to_remove`, or `parity-result.*` / `parity-confirmed.json` is missing

## After user response

- **Proceed** → ensure `scripts/dev-flow-session.sh` exists; if missing, bootstrap the dev-flow mechanical gate first. Then run `bash scripts/dev-flow-session.sh confirm-plan` → implementation may start; stay within confirmed scope only
- **Adjust** → revise plan → ask again
- **No answer** → do not edit code

## `ui_review` note

Read-only `ui_review` evidence (whole-page split + all-unit live comparison with no source edits)
does not require this gate. The **first authorized repair** requires all of the following before
`confirm-plan`:

1. workspace-level `parity-confirmed.json` with `may_proceed_to_fix: true`;
2. required gates configured as `review,runtime,ui_parity`;
3. `In scope` exactly equal to `units_to_fix + runtime_extras_to_remove`.

There is no per-Group `confirmed.json` in the current pipeline. Expanding the authorized id set
requires a new human confirmation artifact before further edits.
