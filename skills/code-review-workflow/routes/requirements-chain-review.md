# Requirements-Chain Review Route

## Activation

Use when the changed behavior is governed by a `.dev-flow/requirements/` artifact. The artifact
must be routed through `index.json` and have `status: approved`.

If the artifact is missing, ambiguous, not approved, or changes during review, return `blocked`.
Do not update the approved artifact with review findings; the artifact is the behavior contract and
the review report is its validation evidence.

## Required evidence

- approved artifact path, `logic_id`, and snapshot/hash;
- changed files and curated diff;
- state matrix, invariants/forbidden states, and affected Golden cases;
- test, targeted validation, runtime, or documented manual evidence for affected cases.

## Reviewer question

Using the approved artifact as authority, independently check:

1. Every implemented or changed state exists in the approved state chain.
2. Every approved state has an implementation path or an explicitly approved non-code reason.
3. Loading, empty, error, retry, offline, missing-data, and fallback branches are approved.
4. No invariant or forbidden state is introduced in code, UI, fallback, tests, or review output.
5. Every affected Golden case is `covered`, `not-covered`, `invalidated`, or `not-applicable`,
   with evidence for `covered`.

Ask the reviewer to attach each finding to an artifact section or stable state/case identifier.
Do not infer business meaning from field names, counts, SDK behavior, or plausible fallback logic.

## Route-specific packet fields

```text
Approved artifact:
Artifact status and hash:
Affected states:
Affected invariants:
Affected Golden cases:
Requirements-chain instructions:
```

## Blocking conditions

- The approved artifact is missing, not approved, ambiguous, or changed during review →
  `blocked`. Do not update the artifact with review findings.
- An implemented or changed state does not exist in the approved state chain.
- A forbidden state is introduced in code, UI, fallback, tests, or review output.
- An approved state has no implementation path and no explicitly approved non-code reason.
- An affected Golden case lacks evidence for a `covered` disposition.
- Reviewer timeout, missing run id, or non-`pass` verdict without explicit human risk acceptance
  recorded via `review-loop`.

## Pass conditions

Report findings along the **Spec / Standards dual-axis** (see parent skill Step 1a):

- **Spec**: no unapproved state, fallback, or UI action remains; no forbidden state is present;
  every affected Golden case has acceptable evidence; the artifact remained unchanged during the
  review.
- **Standards**: all blocking findings (correctness, security, maintainability, test coverage)
  are fixed or explicitly human-accepted; code quality meets the bar.

Per-axis verdict: `pass | revise | blocked`. Overall = weakest axis. One axis must not mask
the other.

## Output status

Return through the parent `code-review-workflow` + `review-loop`:

```text
pass | revise | blocked
```

An MCP response or successful build alone cannot produce `pass`; the dual-axis verdict must be
independently justified and deterministic checks preserved separately from 审查角色 findings.
Use `review-loop` for finding decisions, validation reruns, and the three-round stop gate.
