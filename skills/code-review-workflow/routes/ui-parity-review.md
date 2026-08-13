# UI Parity Review Route

## Activation

Use after `dev-flow ui_review` has produced **authorized source repairs** and needs an independent
Review MCP check on the diff.

This route is **post-fix only**. It does **not** own whole-page Figma decomposition, live parity
comparison, human authorization, source repair, on-device verification, or human repair acceptance.
Those steps are owned by `ui-review`.

Do not use this route to build a new screen; use `figma-ui-gates` from the `feature` path.

## Activation condition

Activate when **all** of the following are true:

1. Whole-page `parity-result.baseline.json` exists.
2. Workspace-level `parity-confirmed.json` authorizes a non-empty `units_to_fix`.
3. Source edits exist for those authorized ids only.
4. Every authorized id has `repair-plan.md` and `repair-verify.json`; accepted ids end `ok`, while
   reverted ids have a verified `revert-verify.json`.
5. Human `repair-accepted.json` exists with no open rework.
6. Parent `code-review-workflow` is invoking Review MCP / fallback.

If any precondition is missing, return `review-blocked` before MCP invocation. Do not re-run parity
or repair work from this route.

## Required evidence

- Canonical Figma URL, screen/state, artifact workspace, and current `session_id`.
- `structure/structure-sweep-complete.json` and `parity-result.baseline.json`.
- `parity-confirmed.json` (`units_to_fix`, skipped, deferred).
- Current `parity-result.json`, including `runtime_extras` dispositions.
- `repair-accepted.json`.
- Per authorized id: `repair-plan.md` plus `repair-verify.json`, or `revert-verify.json`.
- Runtime binding evidence and mandatory `runtime-verified` report.
- Changed files and a curated diff containing actual reviewable hunks.

Screenshots alone are not parity evidence.

## Reviewer question

Does this diff implement **only** the human-authorized parity findings, preserve confirmed
bindings and runtime anchors, avoid inventing/deleting ambiguous or unconfirmed extra elements,
use exported assets for visual units, and retain validated interaction/state behavior?

## Route-specific packet fields

```text
Review route: ui-parity-review
Canonical Figma URL:
Screen / state:
Parity artifact workspace:
Session id:
Baseline parity path + digest:
parity-confirmed.json summary (units_to_fix / skipped / deferred):
Current parity-result.json:
Runtime extras + dispositions:
repair-accepted.json summary:
Per-unit repair/revert verification paths:
Runtime-verified report:
Authorized ids:
Changed files:
Curated diff:
Known risks:
```

Ask the independent reviewer to verify:

1. Diff scope maps exactly to `units_to_fix`; skipped/deferred/`ok` ids are untouched.
2. Accepted and verified-reverted ids exactly cover the authorized set; no open rework remains.
3. Confirmed bindings and `figma.<node-id>` anchors are preserved or intentionally remapped with
   evidence.
4. Exported visual units still use exported assets; no hand-drawn `draw(_:)` substitute was added.
5. Ambiguous, unobserved, blocked, or runtime-extra items were not silently treated as authorized.
6. Runtime evidence comes from the current session/device run and applies the canonical compare
   rules.
7. Interaction/state behavior covered by the repair remains valid.

## Blocking conditions

- Missing/mismatched baseline, `parity-confirmed.json`, `repair-accepted.json`, or session id.
- Changed code cannot be mapped to an authorized id.
- Missing DebugBridge/runtime evidence for an accepted or reverted id.
- `units_rework` is non-empty or acceptance sets do not exactly cover `units_to_fix`.
- Review MCP timeout, missing run id, or non-pass without human risk acceptance
- Diff exceeds authorized ids or edits skipped/deferred/runtime-extra items without disposition.

## Pass conditions

- Independent reviewer verdict `pass` (or residual risks explicitly accepted by the human and
  recorded via `review-loop`)
- Diff limited to authorized parity repairs
- Authorization, acceptance, verification, runtime, and current-session evidence are complete
- No unresolved blocking evidence gaps listed above

## Output status

Return through the parent `code-review-workflow` + `review-loop`:

```text
pass | revise | blocked
```

Use `review-loop` for finding decisions (`fix` / `accept risk` / `not applicable`), validation
reruns, and the three-round stop gate.

## Ownership boundary

| Owner | Owns |
|---|---|
| `ui-review` | Whole-page split, all-unit compare, runtime-extra scan, baseline, authorization, repair, live verify, human acceptance |
| This route | Post-edit Review MCP packet + acceptance of authorized repair diffs |
| `code-review-workflow` base | MCP health, packet transport, fallback, normalized handoff |
| `figma-ui-gates` | New-screen G0–G12 implementation (not this route) |
