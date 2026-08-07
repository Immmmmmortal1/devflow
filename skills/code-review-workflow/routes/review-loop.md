# Shared Review Loop

This protocol applies after the parent `code-review-workflow` returns a reviewer result and a
selected review route interprets it. It owns review iteration, not any domain's acceptance rules.

## Finding decisions

For every finding, record exactly one:

```text
fix | accept risk | not applicable
```

For `fix`, change only confirmed scope, rerun the affected route validation, and run the next
review when the fix materially changes behavior or touched files. For `accept risk`, record the
evidence, impact, reason, and explicit human acceptance. A timeout, missing result, or absent
evidence cannot be classified as risk acceptance by the agent.

## Round contract

Start at the first post-edit review. One round is:

```text
run selected route → invoke base review capability → classify findings
→ fix within scope → targeted validation
```

Record:

```text
Round: 1|2|3
Review route:
Review path: mcp | fallback
Route result: pass | revise | blocked
Finding decisions:
Validation rerun:
```

## Three-round stop gate

After three consecutive rounds without meeting the selected route's acceptance criteria:

- stop and do not enter `commit-gate`;
- return `blocked`;
- include rounds completed, unresolved findings, completed fixes, uncertain boundaries, and
  options requiring human decision;
- resume only after explicit human direction.

Do not keep applying unbounded patches or infer risk acceptance from silence. A route may return
`pass` only after its own criteria and this loop are satisfied.
