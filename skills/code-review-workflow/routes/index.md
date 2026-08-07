# Code Review Routes

These route specifications define review criteria that use the shared capabilities in the parent
`code-review-workflow`. Each route must provide its own required evidence, reviewer instructions,
and final status. The parent owns MCP health, packet construction, invocation, fallback, and result
handoff only.

| Route | Activate when | Route owns |
|---|---|---|
| `code-quality-review` | Any source edit needing generic independent review | correctness, regressions, security, concurrency, and maintainability findings |
| `requirements-chain-review` | An approved requirements artifact governs the changed behavior | state, fallback, invariant, and Golden case compliance |
| `api-contract-review` | API fields or server-driven behavior are changed or consumed | field → business → UI/interaction mapping and contract validation |
| `ui-parity-review` | A UI change has Figma/runtime parity evidence or an authorized UI repair | binding, extra-element, runtime, and approved parity-finding compliance |

All routes also use [review-loop.md](review-loop.md) for finding decisions, validation reruns, and
the three-round stop gate.

Routes may be combined for one change. Run one shared review call per coherent route packet when
the criteria differ materially, then merge route findings before the main agent decides fixes.
Do not create a new route implicitly; add a route specification and update this table first.

## Route handoff contract

Every route must provide:

```text
Review route:
Activation condition:
Required evidence:
Reviewer question:
Route-specific packet fields:
Blocking conditions:
Pass conditions:
Output status:
```

The route may call the parent base capability only through this contract. It must not duplicate
MCP process health checks or invent a second fallback protocol.
