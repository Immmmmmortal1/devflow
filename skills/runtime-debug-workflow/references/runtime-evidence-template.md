# Runtime Evidence Template

Use one report per physical-device validation run. Do not claim a stronger status than the evidence
supports.

```yaml
---
runtime_id: stable.runtime.id
status: runtime-verified|runtime-failed|runtime-blocked
updated_at: "YYYY-MM-DD"
---
```

## Environment

```text
device name/UDID:
iOS version:
project/workspace:
scheme/configuration:
app identity/version:
DEV_FLOW_SESSION_ID:
build/run result:
launch time:
```

## Target flow

```text
approved state/behavior:
entry page:
actions:
expected result:
```

## Correlated evidence

| Step | UI action | UI tree evidence | Current-run log evidence | Result |
|---|---|---|---|---|
| 1 | action/anchor | page/root/node/frame/state | marker/event/time | observed/not observed |

## Diagnostics

```text
diagnostic source edits:
confirm-gate approval:
DEBUG boundary:
stable marker/trace id:
redaction/bounds:
rerun result:
```

## Result

```text
Runtime status:
Verified boundary:
Failed boundary or blocker:
Remaining risks:
Next safe action:
```
