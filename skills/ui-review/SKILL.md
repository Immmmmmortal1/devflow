---
name: ui-review
description: Use from dev-flow's ui_review entry to compare an existing iOS screen with Figma, split the whole page, live-verify every minimum unit via DebugBridge, mark a parity result, and drive human-confirmed code-grounded repairs with on-device re-verification.
---

# UI Review

`ui-review` owns existing-screen Figma parity for `dev-flow ui_review`.

Do **not** use this skill to build a new screen. New Figma UI enters through `feature` →
`figma-ui-gates` after requirements approval and `confirm-plan`.

## Pipeline (current)

```text
Step 0  dev-flow entry: session start --type ui_review → environment-health-check
Step 1  Whole-page Figma split (structure sweep)
Step 2  Compare every minimum unit + scan runtime extras → freeze parity baseline
Step 3  Human confirm parity-result → code-grounded repair (scope / evidence / change / on-device verify)
Step 4  Human confirm whether the repairs are accepted
Step 5  Post-fix ui-parity-review → resolve reviewer findings
Step 6  Record review/runtime/ui_parity gates → commit handoff
```

## Step 0 — dev-flow entry gates

Before Step 1, the dev-flow router owns:

1. `dev-flow-session.sh start --type ui_review`
2. `environment-health-check` — physical App launch preflight, DebugBridge, Review MCP, and
   figma-rest-api must all be `available`
   (this is the dev-flow first gate; `ui-review` does not replace it with its own partial preflight)
3. Do not configure repair-only gates yet. Step 2 is read-only and may conclude with no findings.
   If Step 3.1 produces a non-empty `units_to_fix`, then **before `confirm-plan`** configure:

```bash
bash scripts/dev-flow-session.sh configure-gates --required review,runtime,ui_parity
```

For any source repair, `runtime` and `ui_parity` are mandatory, not optional. The session script
rejects `confirm-plan` for `type=ui_review` unless both are required. A read-only review that never
edits source does not call `confirm-plan`; it may record a bounded read-only review result and end
without commit.

`environment-health-check` already launches the current App and verifies Figma REST + Review MCP +
DebugBridge; re-verify/relaunch if a capability or App run becomes stale mid-flow.

All JSON artifacts owned by this skill include:

```text
producer: ui-review
schema_version: 1
session_id: <current dev-flow session>
artifact_workspace: <canonical absolute workspace path>   # when applicable
```

Run `scripts/validate-ui-review-artifacts.sh` at the end of Steps 1, 2, and 4 with
`--stage split|parity|repair`; a failed validator blocks the next step.

---

## Compare rules (single source of truth)

The minimum-unit implementation and acceptance rules have a **single source of truth** in the
`figma-ui-gates` repository: `figma-ui-gates/rules/*.md`, split by `unit_kind`
(`text`, `button-text`, `button-image`, `button-text-icon`, `image`) plus `rules/screen.md` for
screen-level checks. Each rule file is dual-purpose — implement to it, verify against it — and
defines its own acceptance criteria, tolerance limits, and evidence-normalization shape (enforced
mechanically by `validate-ui-review-artifacts.py`).

**Step 1**, **Step 2**, and **Step 3** must reference `figma-ui-gates/rules/` for every
`unit_kind` they touch. Do **not** restate, summarize, or fork these rules in this file — load the
relevant `rules/*.md` on demand by `unit_kind` and apply it directly. When a page's
`rules_used.json` is present, load only the rule files it names; a `unit_kind` not on the page is
not loaded.

---

## Step 1 — Whole-page Figma split (G2-equivalent hard gate)

**Goal:** Given the Figma URL, split the **entire** target screen using the **same split rules** as
`figma-ui-gates` G1/G2 (visual order, minimum unit, asset-collapse). Finish the whole page and
pass `--stage split` **before** any live comparison.

Step 1 is a **hard gate**, not soft guidance. A stamped `detail-review.json`, a hardcoded
`minimum-unit-index.json`, or a script that also writes `parity-result.*` is a pipeline failure.

### Difference from new UI (`figma-ui-gates`)

| | New UI `figma-ui-gates` | `ui_review` Step 1 |
|---|---|---|
| Split rules | G1 order + G2 minimum unit / collapse | **Same rules (hard gate)** |
| Pace | Split one → implement one | **Split the whole page, then stop** |
| Exit | Current sibling split-complete | **Every first-level Group is split-complete + `--stage split` pass** |
| Artifacts | `gates/G2-*.json` | `groups/*/detail.json` with the same G2 decision fields |

### Inputs

- Canonical Figma URL (with root node)
- Target screen / state
- Artifact workspace: `.dev-flow/ui/by-url/<sanitized-canonical-figma-url>/`

### Actions (order)

1. Lock URL + root node + screen/state → `manifest.json`
2. Figma REST confirm: `figma_rest.py me` + `nodes --depth 1` for the root id (environment-health
   already proved connectivity; this only confirms the requested root exists)
3. Structure (same as `figma-ui-gates` G1):
   - pull root direct children
   - visual sort: same-row by `centerY` → rows top-to-bottom → within row left-to-right by `x`
   - keep original `x/y/w/h`
   - write `structure/frame_struct.md` + `structure/frame_struct_index.json`
4. Screen container classification (same intent as `figma-ui-gates` G4): from Figma structure decide
   whether the screen has list/repeated data, and record the **expected** `screen.base_layout`
   (`UICollectionView` vs adaptive `UIScrollView`) in `structure/screen-classification.json`.
5. Structure Review MCP (same intent as G1 Review), including the screen classification. Write
   `structure/structure-review.json` with real Review MCP evidence (`run_id`, `role=structure`,
   `verdict=pass`). Non-pass stops.
6. Detail sweep (same as `figma-ui-gates` G2) — **recursive, structure order**:
   - process first-level Groups in Structure order
   - decide minimum unit / asset-collapse-eligible with the same G2 rules
   - **assign each minimum unit its `unit_kind`** using the Compare rules taxonomy
     (`text` / `button-text` / `button-image` / `button-text-icon` / `image`) and record the full
     G2 decision fields in `detail.json` (see schema below)
   - non-minimum units keep splitting children until split-complete
   - each detail gets Detail Review MCP **immediately**; write `detail-review.json` with real
     Review MCP evidence (`run_id`, `role=detail`, `verdict=pass`); non-pass stops
   - **do not** bind runtime, compare parity, edit source, or write `parity-result.*` in this step
7. Whole-page complete when every first-level Group is split-complete → write
   `structure/structure-sweep-complete.json` and `structure/minimum-unit-index.json`.
   The index is **only** the aggregation of reviewed `detail.json` `minimum_units`
   (`{figma_id, group_id, name, unit_kind}`). Never hand-author or hardcode the index.
8. Run `validate-ui-review-artifacts.sh --stage split`. Failure blocks Step 2.

### Step 1 outputs

```text
manifest.json
structure/frame_struct.md
structure/frame_struct_index.json
structure/structure-review.json       # Review MCP evidence required
structure/screen-classification.json
structure/minimum-unit-index.json     # derived from reviewed details only
groups/<node-id>/detail.json          # G2 decision fields per minimum unit
groups/<node-id>/detail-review.json   # Review MCP evidence required
structure/structure-sweep-complete.json
```

### G2 decision schema (`groups/<id>/detail.json`)

Each entry in `minimum_units` must include:

```text
figma_id
group_id
name
unit_kind
anchor
is_minimum_unit              # true for rows in this array
asset_collapse_eligible      # bool
has_localizable_text         # bool
has_interaction              # bool
split_status                 # complete | pending_children
pending_child_ids            # [] when complete minimum unit
```

Group file also records `split_status: complete` when the Group sweep is done.

Hard consistency rules (enforced by validator):

- `has_localizable_text == true` ⇒ `asset_collapse_eligible` must be `false`
- `has_localizable_text == true` ⇒ cannot be a `unit_kind: image` minimum unit
- `is_minimum_unit == false` ⇒ must not appear in `minimum_units` or the index
- When `figma/root.depth4.json` (or `figma/root.json`) exists, an `image` unit with
  `asset_collapse_eligible=true` that has TEXT descendants in the dump fails split

### Review MCP evidence schema

`structure/structure-review.json` and each `groups/<id>/detail-review.json` must include:

```text
status: pass
run_id: <non-empty orchestrator run id>
role: structure | detail
verdict: pass
reviewed_at: <ISO-8601 timestamp>
```

Optional when present on the handoff: `provider`, `model`. A file with only `status: pass` and no
`run_id` is invalid.

### Review MCP scope in Step 1

- **Structure Review MCP** — root identity, direct-child completeness, parent/child preservation,
  visual order, original coordinates, and the **expected `screen.base_layout`** decision.
- **Detail Review MCP** (per Group) — minimum-unit decision, asset-collapse eligibility, and the
  **`unit_kind` classification** (e.g. a text+icon button must not be labelled `image`; a
  localizable text node must not be `image`). A wrong `unit_kind` is a non-pass.

### Step 1 hard rules

1. Reuse `figma-ui-gates` G1/G2 split rules; do not invent a second decomposition system.
2. Step 1 passes only when the **whole page** is split-complete **and** `--stage split` passes.
3. Every minimum unit has reviewed G2 decision fields + `unit_kind`; the screen has an expected
   `base_layout`.
4. `manifest.json` records canonical URL, root id, screen/state, `session_id`, schema version, and
   artifact producer. Environment health remains session evidence; do not invent `preflight.json`.
5. No DebugBridge / live UI work in Step 1. Do not start live-compare until `--stage split` passes.
6. No source edits in Step 1.
7. **Do not** generate `parity-result.json` / baseline in the same script or batch as Step 1.
8. **Do not** hardcode `minimum-unit-index.json`; it must equal the union of reviewed
   `detail.json` `minimum_units`.
9. Detail sweep is recursive: a composite with localizable text or interaction is not
   asset-collapse-eligible and must continue splitting.

### Step 1 pass

```text
Structure Review MCP = pass (structure-review.json has run_id + verdict)
Every Group Detail Review MCP = pass (detail-review.json has run_id + verdict)
Every minimum unit has reviewed G2 decision fields + unit_kind
minimum-unit-index.json exactly equals reviewed detail.minimum_units
screen-classification.json (expected base_layout) written
Every first-level Group split-complete
structure-sweep-complete.json written
No source edits
No parity-result.* written yet
validate-ui-review-artifacts --stage split = pass
```

---

## Step 2 — Live compare every minimum unit

**Goal:** Using Step 1’s split result, take **every minimum unit** on the page and, one by one,
find it on the **live rendered UI** and compare against the Figma standard.

**Prerequisite:** `validate-ui-review-artifacts.sh --stage split` has already passed for this
session/workspace. Do not begin DebugBridge lookups, and do not write `parity-result.*`, until
that gate is green.

Requires a wired physical device with the target App running (guaranteed by Step 0
environment-health). Before the first live lookup, confirm DebugBridge is still reachable
(`ensure_ports` + `ping`); if the App is not running, relaunch via XcodeBuildMCP, then continue.
Screenshots are not comparison evidence; use DebugBridge hierarchy / runtime nodes only.

### Pace

```text
For each minimum unit in Structure order (page top-to-bottom, siblings left-to-right):
  enter the declared screen/state → scroll/reveal if needed → locate → compare → record result
Do not skip ahead. Do not batch-claim “looks fine”.
```

### What to compare

Use the **Compare rules** block above as the single source of truth. For each minimum unit, read
its `unit_kind` from Step 1 `detail.json`, then apply that kind's acceptance criteria against the
live DebugBridge node. Do not re-derive the kind here — Step 1 already classified and reviewed it;
if the live node clearly contradicts the classification, that is itself a finding.

Before assigning a parity mark, record:

```text
observation_status: observed | unobserved | blocked
```

- `observed` — the target state was reached and the relevant runtime area was inspected.
- `unobserved` — data/state/scroll/navigation conditions prevented observation.
- `blocked` — build, device, App, or DebugBridge evidence failed.

Only `observed` may produce `ok | wrong | missing`. Binding ambiguity alone is not `missing`;
resolve the binding or leave the row `unobserved`. `unobserved`/`blocked` makes Step 2 incomplete
and must carry the exact next action.

### Screen-level checks (verify Step 1 expectations)

- **`screen.background`** — compare live root/content background color to Figma → `ok | wrong`.
- **`screen.base_layout`** — verify the live container matches the **expected** layout recorded in
  Step 1 `structure/screen-classification.json`:
  - list screen must be collection-based; non-list must be an adaptive-height scroll view
  - findings when it does not match, or when background/scroll ownership is ambiguous or competing
    (more than one primary vertical scroller)

### Step 2 outputs

During the walk, keep per-unit evidence:

```text
groups/<node-id>/live-compare.md
structure/screen-layout-compare.md
```

After the Figma-to-runtime walk, perform the reverse coverage pass over the target root hierarchy.
Record every visible product UI node that is not mapped to a Step 1 unit and is not system chrome,
debug UI, or an explicitly ignored accessibility/container node:

```text
runtime_extras:
  - runtime_anchor:
    class:
    frame:
    evidence:
    disposition: finding | allowed
    reason:
```

An unexplained product node uses `disposition: finding`; it may be authorized for removal only
through Step 3.1. This reverse pass is the **Runtime Extra Scan**; there is no separate undefined
later scan.

When **every** minimum unit, screen-level check, and runtime-extra disposition is complete, write the
**parity result**
(校对结果). This is the Step 2 deliverable.

```text
parity-result.md
parity-result.json
parity-result.baseline.md
parity-result.baseline.json
```

Write `parity-result.baseline.*` in the same Step 2 operation as the first result. Baseline files
are immutable; record their SHA-256 digests in `parity-result.json`.

### Parity result — mark every minimum unit

The result lists **every** minimum unit from Step 1, in Structure order. No unit may be omitted.
Each unit gets exactly one mark:

| Mark | Meaning |
|---|---|
| `ok` | **有，且实现完善** — found on live UI and passes the compare rules for its type |
| `wrong` | **有，但实现不对** — found on live UI, but font/size/color/xy/hash/layout/control model (etc.) fails |
| `missing` | **没有** — Figma unit has no corresponding live implementation |

Optional binding hint (does not replace the mark):

```text
runtime_binding: exact | inferred
```

- `inferred` may still be `ok` or `wrong` based on compare rules

Each unit row at least:

```text
figma_id:
name:
unit_kind: text | button-text | button-image | button-text-icon | image
mark: ok | wrong | missing
observation_status: observed
runtime_binding: exact | inferred | —
summary: one-line why
findings: []          # required when mark is wrong or missing
evidence:             # expected/measured/tolerance + DebugBridge/runtime detail path
```

Screen-level rows use the same three marks:

```text
screen.background    → ok | wrong | missing
screen.base_layout   → ok | wrong | missing
```

`parity-result.md` should be human-readable, grouped by first-level Group, for example:

```text
# Parity result — <screen / state>

## Screen
- background: ok|wrong|missing — ...
- base_layout: ok|wrong|missing — ... (UICollectionView | UIScrollView adaptive)

## Group <name> (<figma_id>)
| figma_id | kind | mark | summary |
|---|---|---|---|
| ... | text | ok | ... |
| ... | image | wrong | hash mismatch |
| ... | button-text | missing | no runtime node |

## Totals
ok: N
wrong: N
missing: N
```

`parity-result.json` must carry the same rows machine-readably
(`units[]` + `screen` + `runtime_extras[]` + `totals` + baseline digests).

### Step 2 hard rules

1. Only after Step 1 `structure-sweep-complete`.
2. Walk **all** minimum units from the split; do not sample.
3. Image/button-image hash mismatch → mark `wrong`; Figma export is authoritative for later repair.
4. Button with text + icon → expect `UIView` + gesture; wrong control model → `wrong`.
5. No screenshot-based “looks the same” → `ok`.
6. Step 2 is incomplete until `parity-result.md` and `parity-result.json` exist and cover every
   minimum unit, screen background/base layout, and the reverse runtime-extra scan.
7. `unobserved` or `blocked` is an evidence state, never silently converted to `missing` or `ok`.

### Step 2 pass

```text
Every minimum unit has mark ok | wrong | missing
Screen background and base_layout marked
parity-result.* + immutable parity-result.baseline.* written together
Totals match the row count
No unit left unvisited
No unobserved/blocked row; every runtime extra has a disposition
validate-ui-review-artifacts --stage parity = pass
```

Step 2 **pass** means the result document is complete — not that every unit is `ok`.

---

## Step 3 — Human confirm → code-grounded repair

**Goal:** After the human confirms the parity result, repair only authorized `wrong` / `missing`
units using the same **code-grounded** loop as other dev-flow edits: lock scope → gather evidence →
plan the change → edit → verify.

Read `code-grounded` and `confirm-gate` when this step starts. Do not edit before confirmation.

### 3.1 Human confirm the parity result

Present `parity-result.md` (and totals). Human decides per row what to do:

| Disposition | Meaning |
|---|---|
| `fix` | Authorize repair for this unit (or screen row) |
| `skip` | Leave as-is this round; record reason |
| `defer` | Not this round; record reason |

Write `parity-confirmed.json`:

```text
confirmed_by: human
confirmed_at: ISO-8601
units_to_fix: [ figma_id ... ]      # from wrong | missing (and any screen.* rows)
runtime_extras_to_remove: [ runtime_anchor ... ] # only extras marked finding
reopened_ok_ids: [ figma_id + human reason ]     # exceptional, baseline ok only
units_skipped: [ figma_id + reason ]
units_deferred: [ figma_id + reason ]
may_proceed_to_fix: true | false
session_id:
artifact_workspace:
```

Hard rules:

- Only rows marked `wrong` or `missing` may appear in `units_to_fix`. A rare human reopening of an
  `ok` row must also appear in `reopened_ok_ids` with a reason; the validator rejects any other id.
- `ok` rows are not edited unless the human explicitly adds them.
- If `may_proceed_to_fix` is false, stop. No source edits.
- Treat authorized `runtime_extras_to_remove` as repair ids for scope, verification, acceptance, and
  set-equality checks. An extra without explicit authorization is untouched.

### 3.2 Confirm-plan (mechanical, once)

Before the **first** source edit in this `ui_review` session:

1. Freeze and verify the Step 2 baseline digests.
2. Configure `--required review,runtime,ui_parity`. This must happen before confirmation because
   required gates cannot change afterward.
3. Output the `confirm-gate` template with scope = `units_to_fix + runtime_extras_to_remove`.
4. Wait for explicit Proceed.
5. Run:

```bash
bash scripts/dev-flow-session.sh confirm-plan --task "ui_review repair"
```

Later units in the same authorized set do not each need a new `confirm-plan` unless the human
expands scope (new ids beyond `parity-confirmed.json`).

### 3.3 Code-grounded loop (per authorized unit)

Process `units_to_fix` in Structure order (same order as Step 1 / Step 2). For **each** unit:

#### A. Lock scope

```text
User asked for: repair parity unit <figma_id> (<unit_kind>) per parity-confirmed.json
Type: ui_review repair
In scope: only this unit's finding(s) and the minimal code needed to fix them
Out of scope: other units, refactors, unrelated cleanup
Evidence read: (filled in B)
```

Do not pull in neighboring units “while here”.

#### B. Find evidence

Before claiming how to change, gather:

| Need | Evidence |
|---|---|
| What Figma requires | Step 1 detail + Step 2 compare record for this `figma_id` |
| What live UI is now | DebugBridge runtime detail for the bound node (or proof of `missing`) |
| What code owns it today | `Read` / `grep` → path + line range of the implementing view/controller |
| Asset truth (image / button-image) | Figma export path + current bundle asset name/hash when relevant |

If any row is unknown → output only unknowns + next read/command. **No edit.**

#### C. How to change

Plan the edit so the unit will satisfy the **Compare rules** block for its `unit_kind`. The target
state is exactly that kind's acceptance criteria — do not invent a different rule set here:

- `text` / `button-text` → fix font/size/color/xy; remove hard-coded width/height; keep
  `numberOfLines = 0` and localization-safe. `missing` → add the label with correct attrs + origin.
- `button-image` / `image` → export the Figma asset and replace the runtime image; `missing` → add
  `UIImageView` (or image button) with the exported asset at the Figma frame.
- `button-text-icon` → `UIView` + tap gesture; text by `text` criteria, icon by image-hash criteria.
- `screen.background` → fix root/content background color.
- `screen.base_layout` → match the Step 1 expected container (list → `UICollectionView`; non-list →
  adaptive-height `UIScrollView`).

Record the plan in the unit’s repair note before editing:

```text
groups/<node-id>/repair-plan.md
```

#### D. Edit

- Change only files required by the plan for this unit
- Stay inside `parity-confirmed.json` scope
- No drive-by formatting or refactors

#### E. How to verify (mandatory live loop)

After **each** edit for this unit, the agent must **itself** re-check on a wired physical device.
Do not ask the human to “look at the screen” as a substitute. Do not use screenshots as evidence.
Read and execute `runtime-debug-workflow` for the build/install/launch and DebugBridge lifecycle;
this step supplies parity criteria while that skill supplies current-run runtime evidence.

Closed loop:

```text
edit
→ build / install / launch on wired device
→ DebugBridge: inspect live rendered UI for this unit
→ re-apply the Compare rules for this unit_kind (same criteria as Step 2)
→ mark_after = ok | wrong | missing
→ if not ok → continue editing the same unit (back to C → D → E)
→ only leave the loop when mark_after is ok, or hard-blocked with recorded reason
```

DebugBridge checks (minimum):

1. Find the runtime node (prefer `figma.<node-id>`; else unique inferred binding with evidence)
2. Read live attributes needed for this `unit_kind` (text font/size/color/origin, image presence,
   control type, frame, background, scroll/collection host as applicable)
3. Compare against the Figma standard from Step 1 detail + Step 2 finding
4. Persist runtime evidence path(s) used for this round

Write / append:

```text
groups/<node-id>/repair-verify.md
groups/<node-id>/repair-verify.json
```

```text
figma_id:
session_id:
artifact_workspace:
repair_round: 1|2|3|...
attempt: 1|2|3|...
mark_before: wrong | missing
mark_after: ok | wrong | missing
result: ok | blocked
debugbridge_evidence:
runtime_report:
compare_notes:
residual_findings: []
next: done | continue-edit | blocked
```

Hard rules for the loop:

1. `mark_after: wrong` or still `missing` → **must continue modify** the same unit; do not advance
   to the next `units_to_fix` id.
2. Each continue-edit round needs an updated repair plan note (what was still wrong + what you will
   change next). Blind retries without new evidence are forbidden.
3. Cap attempts at **3 per unit per repair round**. If still not `ok`, mark that round `blocked`,
   record residual findings, and ask the human in Step 4. A human `rework` starts a new numbered
   repair round with a fresh three-attempt budget; keep cumulative history.
4. Build failure or DebugBridge unavailable → `blocked` for the unit; do not claim verify pass.
5. Only when `mark_after` is `ok` may the next `units_to_fix` item start.

Maintain one aggregate runtime gate report for the final authorized set:

```text
producer: runtime-debug-workflow
schema_version: 1
session_id:
gate: runtime
status: runtime-verified | runtime-failed | runtime-blocked
artifact_workspace:
parity_confirmed_report:
verified_ids: []       # exactly units_to_fix + runtime_extras_to_remove when verified
debugbridge_evidence: []
evidence:
```

### 3.4 Refresh parity result after repairs

The immutable Step 2 `parity-result.baseline.*` already exists and must never be overwritten.
When the authorized set is done (or the session stops mid-set), rewrite the live result so marks
reflect post-repair reality:

```text
parity-result.md
parity-result.json
```

Keep skipped/deferred ids annotated from `parity-confirmed.json`. The baseline plus the refreshed
result together show first-round vs post-repair for later debugging.

### Step 3 hard rules

1. No edits without `parity-confirmed.json`, baseline digest verification, and
   `may_proceed_to_fix: true`.
2. No edits without mandatory `review,runtime,ui_parity` gates configured and `confirm-plan` for
   the first repair.
3. `code-grounded`: empty Evidence read → hard stop; no speculative fixes.
4. One authorized unit at a time: scope → evidence → plan → edit → **DebugBridge live verify** →
   if not ok continue edit; a blocked round stops the repair set for Step 4 disposition, and only
   `ok` may advance directly to the next id.
5. Do not “fix” `ok` or `skip`/`defer` rows.
6. Verification is **agent-driven** wired-device DebugBridge + the Compare rules block, not
   screenshots and not “please check on your phone”.
7. Not fixed correctly (`wrong` / still `missing`) ⇒ keep modifying; never mark the unit done early.

### Step 3 pass

```text
parity-confirmed.json present
Every authorized repair id has repair-plan.md + repair-verify.md/.json with DebugBridge evidence
Each unit ended with mark_after ok, or blocked after ≤3 attempts with residual recorded
parity-result.* refreshed
```

Step 3 pass means repairs were executed and **live-verified** — **not** that the human has
accepted them. Acceptance is Step 4.

---

## Step 4 — Human confirm whether repairs are accepted

**Goal:** After Step 3 edits and per-unit verify, present what changed and get an explicit human
decision: accept, rework, or verified-revert. No commit / no closing the review without this.

### Present to the human

For every id in `parity-confirmed.json` → `units_to_fix + runtime_extras_to_remove`:

```text
figma_id / name / unit_kind
mark_before → mark_after
summary of code change (files)
repair-verify evidence (DebugBridge)
residual findings if any
```

Also show refreshed `parity-result.md` totals.

### Human dispositions

Exactly one per unit (mutually exclusive):

| Disposition | Meaning | Next |
|---|---|---|
| `accept` | A repair with `mark_after: ok` is accepted | Unit closed for this round |
| `rework` | Attempt kept, needs another repair round | Increment `repair_round`, return to Step 3.3 for this unit, then Step 4 again |
| `revert` | Repair rejected; restore pre-repair behavior | Execute the verified revert protocol below |

`revert` is an action, not a label:

1. lock scope to the rejected id and map its exact diff ownership;
2. write `groups/<node-id>/revert-plan.md`, including shared-file/shared-constraint risks;
3. revert only that id without changing accepted ids;
4. rebuild/install/launch on the wired device and verify both the reverted id and any accepted
   neighboring ids through DebugBridge;
5. write `groups/<node-id>/revert-verify.json` with `result: reverted`, current `session_id`,
   DebugBridge/runtime evidence, and restored parity mark;
6. refresh `parity-result.*`.

If isolated revert cannot be proven, disposition remains `rework`; it is not resolved.

Write `repair-accepted.json`:

```text
confirmed_by: human
confirmed_at: ISO-8601
session_id:
artifact_workspace:
units_accepted: [ figma_id ... ]
units_rework: [ figma_id + reason ]
units_reverted: [ figma_id + reason ]
verification_reports: { figma_id: repair-verify.json path }
revert_verification_reports: { figma_id: revert-verify.json path }
all_authorized_repairs_resolved: true | false
```

`all_authorized_repairs_resolved` is `true` only when accepted and verified-reverted ids are
disjoint, their union exactly equals `units_to_fix + runtime_extras_to_remove`, every accepted id
has final `mark_after: ok`, every reverted id has `revert-verify.json`, and `units_rework` is empty.

### Step 4 hard rules

1. Agent must not self-accept repairs. `repair-verify.md` with `mark_after: ok` is not acceptance.
2. `accept` is invalid for a blocked/wrong/missing repair; choose `rework` or verified `revert`.
3. No `commit-gate` / commit until Steps 5–6 complete.
4. Skipped / deferred units from Step 3.1 stay skipped/deferred; they are not part of Step 4 unless
   the human later moves them into a new `parity-confirmed.json`.

### Step 4 pass

```text
repair-accepted.json present
Every authorized unit/extra id is accepted or verified-reverted; no open rework
all_authorized_repairs_resolved: true
validate-ui-review-artifacts --stage repair = pass
```

---

## Step 5 — Post-fix independent review

After Step 4 passes, read `code-review-workflow` and route `ui-parity-review`. Supply actual diff
hunks plus the baseline, authorization, current parity, per-id verification/revert evidence,
runtime-extra dispositions, `repair-accepted.json`, and the current `runtime-verified` report.

The route returns `pass | revise | blocked`:

- `revise` → use `review-loop`; any source edit returns to the affected Step 3 repair round,
  wired-device verification, and Step 4 human acceptance.
- `blocked` / timeout / missing evidence → stop; never record a passing review gate.
- `pass` → write the bounded review gate report. Human-accepted residual risk must be explicit in
  the review-loop artifact.

The repair review report must include:

```text
producer: code-review-workflow
schema_version: 1
session_id:
gate: review
status: pass
route: ui-parity-review
source_edits: true
reviewer_result: pass
run_id:
diff_evidence:
artifact_workspace:
baseline_report:
parity_confirmed_report:
repair_accepted_report:
evidence:
```

### Step 5 pass

```text
ui-parity-review = pass
No unresolved reviewer findings
Final diff still equals authorized repair scope
```

## Step 6 — Mechanical gates and commit handoff

Only after Step 5 passes, record in this order:

```bash
bash scripts/dev-flow-session.sh record-gate --name review --report <review-report.json>
bash scripts/dev-flow-session.sh record-gate --name runtime --report <runtime-report.json>
bash scripts/dev-flow-session.sh record-gate --name ui_parity --report <ui-parity-report.json>
```

The `ui-parity` report contract is:

```text
producer: ui-review
schema_version: 1
session_id:
gate: ui_parity
status: accepted
artifact_workspace:
parity_confirmed_report:
repair_accepted_report:
artifact_validation_report:  # validate-ui-review-artifacts --stage all output
evidence:
```

Run `validate-ui-review-artifacts.sh --stage all` before recording the gate. Then hand off to `commit-gate`;
the user still separately authorizes the exact commit scope. `approve-commit` must fail if review,
runtime, or ui_parity is missing.

A read-only session with no repairs writes a `review` report with
`route: ui-review-read-only`, `source_edits: false`, `artifact_workspace`, and a passing
`artifact_validation_report` from `--stage parity`. `record-gate` reruns the validator before
accepting it. The session records this report without `confirm-plan` and ends; it has no commit
handoff.

## Ownership boundary

| Owner | Owns |
|---|---|
| `ui-review` | Step 1–6 (split, compare/extras, baseline, repair, live verify, acceptance, post-review, gates) |
| `code-grounded` / `confirm-gate` | Scope/evidence discipline and first-edit confirmation |
| `figma-ui-gates` | New-screen G0–G12; **split rule source** for Step 1 |
| `ui-parity-review` route | Post-fix Review MCP on authorized diffs only |
