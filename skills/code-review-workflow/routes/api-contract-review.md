# API Contract Review Route

## Activation

Use when `api-contract` is active and the change adds, changes, or consumes endpoint fields,
mock payloads, or server-driven business/UI behavior.

## Required evidence

- authoritative API document, capture, fixture, or source contract;
- endpoint and request/response field list;
- field → business state → UI/interaction mapping;
- intentionally unused fields with reasons;
- Golden payload cases and contract validation results.

## Reviewer question

Independently verify that the diff preserves the endpoint contract and does not turn field names,
counts, optional values, or local fallback behavior into unsupported business meaning. Check that
each consumed field has a business/UI owner, refresh/error behavior is preserved, and Golden cases
cover empty, actionable, completed/disabled, boundary, permission, and API failure states where
applicable.

## Route-specific packet fields

```text
Review route: api-contract-review
Authoritative API contract source:
Endpoint:
Request fields:
Response fields:
Field → business state → UI/interaction mapping:
Intentionally unused fields + reasons:
Golden payload cases:
Contract validation results:
```

The reviewer must receive the authoritative contract source and the field mapping — inferring
contract meaning from code or chat history is not sufficient.

## Blocking conditions

- Missing authoritative API contract source (document, capture, fixture, or source contract).
- A consumed field is not mapped and lacks an explicit unused reason.
- An undocumented field, state inference, or contract-breaking fallback is introduced.
- Contract Golden cases (empty, actionable, completed/disabled, boundary, permission, API
  failure) were not validated.
- Reviewer timeout, missing run id, or non-`pass` verdict without explicit human risk acceptance
  recorded via `review-loop`.

## Pass conditions

Report findings along the **Spec / Standards dual-axis** (see parent skill Step 1a):

- **Spec**: every consumed field is mapped or explicitly unused; no undocumented field, state
  inference, or contract-breaking fallback is introduced; contract Golden cases were validated.
- **Standards**: all blocking findings (correctness, security, error handling, maintainability)
  are fixed or explicitly human-accepted.

Per-axis verdict: `pass | revise | blocked`. Overall = weakest axis. One axis must not mask
the other.

## Output status

Return through the parent `code-review-workflow` + `review-loop`:

```text
pass | revise | blocked
```

Use `review-loop` for finding decisions (`fix` / `accept risk` / `not applicable`), validation
reruns, and the three-round stop gate. A reviewer response alone cannot produce `pass`; the
dual-axis verdict must be independently justified on both axes.
