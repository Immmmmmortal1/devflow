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

1. **`bugkb findings`** — not empty; not placeholders (`n/a`, `none`, `无`, `待查`, `TBD`). Must cite at least one concrete search outcome: similar bug id/title, pattern hit, or explicit “bugkb searched, no similar cases” with query/scope stated.
2. **`Analysis tool used`** — must include **`gstack-investigate`** (and **`gstack-review`**). If investigate is missing → run investigate first; do not confirm.
3. **`Root cause`** — tied to investigation evidence: file path + line range, log/stack trace, or repro step — not speculation.

### Feature (`Type: feature`)

- **`Analysis tool used`** — must include **`gstack-review`**
- **`bugkb findings`** — leave `n/a (pre-implementation; runs after implementation per feature-workflow)` — do not run pre-implementation bugkb unless user asked

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
- **Feature:** `Analysis tool used` omits `gstack-review`
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
