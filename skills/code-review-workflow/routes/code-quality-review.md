# Code Quality Review Route

## Activation

Use for a source edit that needs an independent review and has no more specific review contract,
or combine it with a specialized route when both generic code risks and domain rules matter.

## Required evidence

- confirmed user scope;
- changed files and curated diff;
- relevant callers/types/configuration;
- tests, build, lint, and runtime results already run;
- known risks and unverified boundaries.

## Reviewer question

Review the changed behavior for correctness, regression risk, error handling, security/privacy,
concurrency, resource ownership, and maintainability. Report each finding with severity,
confidence, exact location, why it is a real issue, and a concrete remediation.

Do not ask this route to decide requirements semantics, API field meaning, or Figma parity without
the corresponding specialized route and evidence.

## Route-specific packet fields

```text
Review route: code-quality-review
Changed files:
Curated diff:
Confirmed scope:
Validation run:
Known risks:
Unverified boundaries:
```

This route uses the shared review packet (see parent skill Step 2) with no extra domain-specific
fields. The reviewer must receive actual reviewable code and the confirmed scope — a diff path
or chat summary is not sufficient.

## Blocking conditions

- Missing confirmed user scope or a curated diff with reviewable hunks.
- Missing tests, build, lint, or runtime results that were already required before review.
- Reviewer timeout, missing run id, or a non-`pass` verdict without explicit human risk acceptance
  recorded via `review-loop`.
- The diff introduces unrequested behavior that cannot be mapped to the confirmed scope.
- A blocking or high-confidence finding remains unfixed and not explicitly human-accepted.

## Pass conditions

Report findings along the **Spec / Standards dual-axis** (see parent skill Step 1a):

- **Spec**: the change matches the confirmed user scope and does not introduce unrequested
  behavior.
- **Standards**: the reviewer received reviewable code and the confirmed scope; all
  blocking/high-confidence findings are fixed or explicitly human-accepted; affected validation
  was rerun after fixes; no unresolved route blocker remains.

Per-axis verdict: `pass | revise | blocked`. Overall = weakest axis. One axis must not mask
the other.

## Output status

Return through the parent `code-review-workflow` + `review-loop`:

```text
pass | revise | blocked
```

Use `review-loop` for finding decisions (`fix` / `accept risk` / `not applicable`), validation
reruns, and the three-round stop gate. A reviewer response or a successful build alone cannot
produce `pass`; the dual-axis verdict must be independently justified on both axes.
