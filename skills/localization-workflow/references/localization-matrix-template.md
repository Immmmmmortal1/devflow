# Localization Matrix Template

Replace every placeholder. Keep this artifact with the dev-flow task evidence; do not include it
in a product commit unless explicitly requested.

```yaml
---
localization_id: stable.localization.id
status: ready|blocked
title: Human readable copy change
updated_at: "YYYY-MM-DD"
---
```

## Locale contract

| Locale | Configuration/source | Supported | Resource format | Fallback owner |
|---|---|---|---|---|
| locale | path/config key | yes/no | strings/json/yaml/etc. | source or system |

## Semantic scope

| Key/entry | Meaning/state | Authoritative source | In scope | Related occurrences |
|---|---|---|---|---|
| key | action or state | path/user/glossary | yes/no | paths |

## Locale matrix

| Locale | Key/entry | Current value | Target value | Target source | Status | Validation |
|---|---|---|---|---|---|---|
| locale | key | old value | new value | source | ready/blocked/exception | check |

## Same-string exceptions

```text
exception_id:
source_locale:
exact_string:
affected_locales:
scope:
reason:
explicit_user_authorization:
not_a_translation: true
review_condition:
validation:
```

## Contract checks

- Placeholders/variables:
- Markup/escaping:
- Plural/select categories:
- Accessibility meaning:
- Hardcoded or fallback duplicates:

## Validation and handoff

```text
Localization status:
Supported locales:
Semantic scope:
Exceptions:
Validation:
Open decisions/blockers:
Source-edit confirmation: required through confirm-gate
```
