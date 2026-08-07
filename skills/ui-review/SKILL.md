---
name: ui-review
description: Use from dev-flow's ui_review entry when an existing iOS screen needs Figma parity review, runtime binding, extra-element confirmation, or an authorized repair.
---

# UI Review Entry

`ui-review` is the compatibility entry for `dev-flow ui_review`. The complete review criteria are
owned by the `code-review-workflow` route:

```text
code-review-workflow/routes/ui-parity-review.md
```

Read that route before executing the review. It owns the Figma-first prefix, node/runtime binding,
UILabel rule, Runtime Extra Scan, difficult-container rules, Review MCP handoff, and final parity
status. The parent `code-review-workflow` owns only MCP health, packet construction, invocation,
fallback, and normalized reviewer handoff.

Do not use this entry to build a new screen; a new screen enters through `feature` and then routes
to `figma-ui-gates` after requirements approval and confirmation.

Source repairs still require `confirm-gate`, the `ui-parity-review` route's review loop, and
`commit-gate` before commit.
