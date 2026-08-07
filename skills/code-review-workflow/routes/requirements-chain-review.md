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

## Pass conditions

- no unapproved state, fallback, or UI action remains;
- no forbidden state is present;
- every affected Golden case has acceptable evidence;
- all blocking findings are fixed or explicitly human-accepted;
- the artifact remained unchanged during the review.

An MCP response or successful build alone cannot produce `pass`. Return `pass`, `revise`, or
`blocked` and preserve deterministic checks separately from Review MCP findings.
