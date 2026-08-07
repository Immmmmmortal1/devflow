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

## Pass conditions

- the reviewer received reviewable code and the confirmed scope;
- all blocking/high-confidence findings are fixed or explicitly human-accepted;
- affected validation was rerun after fixes;
- no unresolved route blocker remains.

Return `pass`, `revise`, or `blocked` with the base review envelope attached.
