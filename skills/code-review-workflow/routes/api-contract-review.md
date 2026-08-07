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

## Pass conditions

- every consumed field is mapped or explicitly unused;
- no undocumented field, state inference, or contract-breaking fallback is introduced;
- contract Golden cases were validated;
- all blocking findings are fixed or explicitly human-accepted.

Return `pass`, `revise`, or `blocked` with the base review envelope attached.
