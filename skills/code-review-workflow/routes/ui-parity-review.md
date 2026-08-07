# UI Parity Review Route

## Activation

Use for `dev-flow ui_review` when an existing UIKit screen must be compared with a Figma screen or
when an authorized UI repair needs a parity recheck. This route owns the complete Figma-first
review criteria. The parent `code-review-workflow` supplies only the independent Review MCP
transport and review handoff.

Do not use this route to build a new screen; use `figma-ui-gates` from the `feature` path for a new
Figma-driven screen.

## Figma-first evidence prefix

Lock the Figma URL, target screen/state, device/OS/viewport, project root, comparison scope, and
artifact workspace under:

```text
.dev-flow/ui/by-url/<sanitized-canonical-figma-url>/
```

Run the shared prefix in order:

```text
Figma URL
→ G0 scope lock
→ G1 root metadata + first-level Group structure
→ G1 review MCP gate
→ G2 current Group detail
→ G2 review MCP gate
→ G3 REST design evidence
→ G4 Group classification
→ top-to-bottom Figma Group sweep
```

Use `figma-rest-api` for node and rendered reference evidence. Do not treat REST output as Figma
MCP output, and do not use runtime screenshots as a substitute for node evidence. Reuse the
URL-named artifact workspace, `frame_struct.md`, `frame_struct_index.json`, node detail JSON,
ownership labels, and the same Figma node ids used by the feature's `figma-ui-gates` sub-route.

## Runtime binding and comparison

For every Figma Group or minimum unit, inspect the existing UIKit implementation and record one:

```text
exact       accessibilityIdentifier is figma.<node-id>
inferred    unique match from hierarchy, frame, type, text, or asset
collapsed   parent asset/container is the intended runtime unit
system      system-owned element; child binding is not required
ambiguous   multiple runtime candidates; do not choose silently
missing     Figma node has no runtime implementation
```

`ambiguous` and `missing` remain findings. Never invent an anchor or treat a visually similar node
as a match. After the complete top-to-bottom sweep, compare structure, frame, text, typography,
color, asset, interaction, and adaptive behavior for every bound element.

### Label rule

For every app-owned `UILabel`, check the existing SnapKit layout:

```text
UILabel → SnapKit layout → numberOfLines = 0 → no extra fixed-height constraint
```

The Figma label height is the expected rendered result; do not copy it into
`height.equalTo(...)` or another fixed-height constraint.

### Difficult bindings

- A unique runtime candidate without a deterministic anchor is `inferred` and requires hierarchy,
  frame, type, or text evidence.
- Multiple candidates are `ambiguous`; never force a mapping.
- For a combined asset group, bind the parent and record the collapse instead of inventing child
  anchors.
- For `UITableView` or `UICollectionView`, bind the list/container and reusable cell structure;
  do not require a permanent Figma node for each dynamic row.
- For `BaseScrolleController`, verify the single primary scroll owner, content height, bottom
  closure, and final-control reachability.
- A missing accessibility identifier is an anchor-remediation finding, not proof that the visual
  element is missing.

## Runtime Extra Scan

After the normal Figma binding pass, use DebugBridge from the implemented screen's runtime root
and traverse visible UIKit elements top-to-bottom. Every runtime element not already bound becomes
a `runtime-extra` candidate. Record:

```text
runtime anchor/id:
runtime type:
parent hierarchy:
frame:
text/asset description:
source location if known:
reason not bound to Figma:
confirmation: pending | keep | adjust | delete | system-exempt | dynamic-exempt
evidence:
```

Do not immediately classify an unbound element as an error. Require human confirmation:

- `system-exempt`: status bar, navigation/system chrome, keyboard, or other OS-owned surface;
- `dynamic-exempt`: data/state-generated content not represented by this Figma state;
- `keep`: intentional product/runtime element required by approved behavior;
- `adjust`: valid element whose position, size, style, or visibility needs correction;
- `delete`: implementation residue that should not exist;
- `pending`: insufficient evidence to decide.

An unconfirmed candidate remains open. It cannot be silently deleted, ignored, or counted as a
Figma mismatch.

## Review MCP handoff

When source changes or an authorized repair needs independent review, call the parent
`code-review-workflow` with route `ui-parity-review`. The route-specific packet must include:

- canonical Figma URL and scoped groups/states;
- Figma node/render evidence paths;
- runtime binding table and DebugBridge UIWindow/tree evidence;
- extra-element confirmations and authorized finding ids;
- changed files, curated diff, and verifier/runtime results.

Ask the independent reviewer to verify that the diff implements only authorized parity changes,
preserves confirmed bindings and runtime anchors, does not silently invent/delete ambiguous
elements, and retains validated interaction/state behavior. A screenshot alone is not parity
evidence.

Use the parent `review-loop` for finding decisions, validation reruns, and the three-round stop
gate. The Review MCP response does not replace Figma REST or DebugBridge evidence.

## Result contract

Record the original and canonical Figma URL, artifact workspace, Figma evidence paths, runtime
tree evidence, binding table, extra-element confirmations, finding ids, authorized repairs,
reviewer run id/verdict, parity result, and verifier result.

Return exactly one status:

- `pass`: all scoped bindings and extras are confirmed and no actionable discrepancy remains;
- `complete-with-findings`: evidence is complete, but confirmed adjustments, deletions, or
  missing bindings remain;
- `blocked`: required Figma state, runtime state, binding evidence, reviewer result, tool, or
  human confirmation is unavailable.

Never claim UI completion from a screenshot, visual similarity guess, or missing binding/reviewer/
verifier evidence.
