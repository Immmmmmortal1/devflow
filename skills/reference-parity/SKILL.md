---
name: reference-parity
description: Enforce contract parity when the user names a reference implementation or task is port/migrate to match existing code. Read reference first, copy contract (e.g. payload keys), diff against SDK/builder output, require golden validation and pre-commit parity report. Not global; activates only on evidence.
---

# Reference Parity

## When to activate

**Only** when:

- user names 参考 / 范文 / 按 X 接 / 与 XX 一致
- task is explicitly port/migrate to match existing code or API

Do **not** activate for greenfield work with no named reference.

## Phase 0 — read reference (before plan)

1. Open exact reference (file + line range, or doc section).
2. Copy contract literally:
   - JSON/dict → sorted **key list**
   - API → signature + behavior notes
3. Paste into plan — do not paraphrase from memory.

`must_not_have` = likely SDK/builder output keys **minus** reference contract **minus** user-approved deviations.

## Phase 1 — plan additions

- Reference path
- Reference contract
- Diff: `must_have`, `must_not_have`, `source_mapping`
- SDK decision: `BANNED` (hand-build only) or `DIFF-THEN-USE` (extra keys block until user approves)
- Golden validation (test/script that fails on added/removed keys)

## Phase 2 — implementation

1. Do not add contract items without user approval.
2. Do not trust SDK README over reference diff.
3. Comment at payload/API assembly boundary: which reference this mirrors.
4. Do not write tests asserting unapproved extra keys.

## Phase 3 — pre-commit parity report

```text
Reference:
Reference contract: [...]
Actual output: [...]
Added: [...]           # must be empty
Removed: [...]         # must be empty unless approved
Forbidden hits: [...]  # must be empty
Golden validation: pass | fail | not run
```

Non-empty Added/Forbidden or golden not run → stop; no commit gate.

## Appendix — Purchase/Order verify dict tasks only

When reference is a hand-built purchase verify/report dict, watch for unapproved SDK extras such as:

- `signed_transaction_jws`
- `original_order_id`
- `expiration_date`
- `purchase_date`
- `display_price`

Appendix applies only to that task shape.

Example reference key list: `examples/purchase-verify-reference-keys.json` in this skill directory (for manual parity reports and unit-test fixtures).
