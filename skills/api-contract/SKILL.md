---
name: api-contract
description: Mandatory API integration gate. Use before coding when a task adds, changes, or consumes an API endpoint, response field, request field, Feishu/API document, mock payload, or server-driven UI behavior.
---

# API Contract Gate

## Purpose

Prevent "fields are wired but business is wrong" failures. API integration must prove the path from endpoint contract to business state, UI state, interaction, and validation before source edits.

## When

Activate this gate when any task includes:

- New endpoint or changed endpoint.
- New response/request fields.
- API document, Feishu document, Postman/cURL, packet capture, or mock payload.
- Server-driven UI, button state, entitlement, reward, pricing, status, red dot, notification, or permission.
- Bug report saying fields/business/UI/interaction do not match.

If the user only asks to list fields, do read-only contract extraction and do not require implementation confirmation.

## Required Evidence

Use primary source first:

- API document or Feishu document provided by the user.
- Actual response capture or mock fixture.
- Existing model/request code.
- Existing UI/business code that consumes the fields.

For Feishu documents in this user's workspace, use the configured Feishu document access path preferred by the project/user memory. Do not switch tools without explicit approval.

## Contract Extraction

Before planning code, produce an endpoint contract:

```text
Endpoint:
Method:
Request fields:
Response fields:
Nested fields:
Error/empty states:
Refresh/retry requirement:
```

Do not summarize fields as "etc." Every consumed field must be named.

## Business Mapping Table

Before coding, produce this table for every endpoint that drives behavior:

```text
API field | Meaning from doc/source | Business state | UI/interaction owner | Expected behavior | Validation case
```

Rules:

1. A field is not "integrated" until it maps to a business state or is explicitly marked unused with a reason.
2. Do not infer semantics from field names when docs/source provide wording.
3. Do not use aggregate/count fields as day/status fields unless the contract explicitly says so.
4. Prefer server-provided current/next/actionable fields for UI decisions.
5. If doc wording conflicts with product instruction, stop and ask or record the product instruction as the higher-priority override.

## Golden Cases

Before coding, define golden cases with concrete payloads or field values:

```text
Case:
Input payload/state:
Expected business state:
Expected UI:
Expected interaction:
```

Minimum cases for stateful APIs:

- Empty/default state.
- Actionable state.
- Already completed/disabled state.
- Boundary day/count/status.
- VIP/permission/entitlement variant when applicable.
- Network/API failure fallback.

For date/week/day logic, include exact calendar dates and expected day numbers.

## Implementation Rules

1. Model names and optionality must match the contract.
2. UI must consume a business view state, not raw API fields spread across views.
3. Refresh requirements from the doc must be wired to the owning screen.
4. Local fallback/cache must not override fresher server state unless explicitly designed.
5. Any intentionally unused field must be listed in the plan/review handoff.

## Validation

At least one validation must prove contract mapping, not just compilation:

- Unit test/view-state test with golden payloads.
- Scripted decoder/view-state check.
- Mock/manual verification using the golden cases.
- If only build is possible, state that contract behavior is not runtime-verified and list the remaining cases for manual self-test.

## Confirm-Gate Requirements

When this gate is active, the confirmation plan must include:

- `API contract source:`
- `Endpoint contract:`
- `Business mapping table:`
- `Golden cases:`
- `Unused fields:`
- `Contract validation:`

Hard stop before coding if any consumed API field lacks a business/UI mapping or validation case.

## Review Requirements

The code review handoff must include:

- API fields consumed.
- API fields intentionally unused.
- Mapping changes from API field to business state.
- Golden cases validated and not validated.
- Remaining manual self-test cases.
