# Review Packet Template

Use this as the minimum handoff to an independent code reviewer. Keep the diff short enough for
the tool timeout; attach or reference large artifacts only under validation and known risks.

```text
User request:
Confirmed scope:
Classification: feature | bug | authorized-ui-repair

Task summary:
Changed files:
- path: intent

Diff:
- curated relevant hunks or behavior-level diff summary

Evidence read:
- path / identifier: what it proves

Validation:
- command or manual check: result

Approved requirements chain:
- artifact path:
- states/invariants relevant to this diff:
- Golden cases covered:

Active skills:
Known risks:
Unverified boundaries:
Reviewer request:
- severity and confidence for each finding
- exact file/line or symbol
- why it violates scope, requirements, or code behavior
- concrete remediation
- classify each finding as Spec or Standards axis (see parent skill Step 1a)

Dual-axis report (mandatory in reviewer output):
```text
Spec verdict: pass | revise | blocked
  - Spec findings: (list or none)
Standards verdict: pass | revise | blocked
  - Standards findings: (list or none)
Overall result: pass | revise | blocked  (weakest axis)
```

Required machine fields for an orchestrator request:

```json
{
  "task_summary": "...",
  "changed_files": ["..."],
  "diff": "..."
}
```

Do not use a file path as the only value of `diff`. Do not include credentials, tokens, cookies,
signatures, user/device identifiers, or unbounded logs.
