---
name: localization-workflow
description: Use when localized copy, string catalogs, translation tables, locale files, fallback text, or locale-specific UI content is added, changed, audited, or reported missing.
---

# Localization Workflow

## Overview

Keep every supported locale aligned with the same semantic copy change. Discover the actual locale
set, map each locale to an authoritative target value, record explicit same-string exceptions, and
validate the complete matrix before handing source edits to `confirm-gate`.

This skill owns localization completeness. It does not define business states, API semantics, UI
layout, or commit approval.

## Activate for

- localized copy or string resource changes;
- adding/removing a supported locale;
- missing, stale, untranslated, or fallback locale content;
- copy that varies by state, plural, gender, context, or platform;
- requests to temporarily reuse one locale's exact string in another locale.

If the copy change also changes a state transition or interaction, activate `requirements-closure`
for the behavior contract. Use `api-contract` for API-driven values. Use `confirm-gate` before
source edits; this workflow does not authorize editing.

## Hard rules

1. Enumerate locales from the project's actual configuration and resource tree. Never assume the
   first matching file or only the locale named by the user is the complete scope.
2. Match semantic keys, not just identical source text. Find aliases, hardcoded copies, state
   variants, plural forms, accessibility text, tests, and fallback resources where applicable.
3. Every required locale must have an authoritative target value or a specifically recorded,
   user-approved exception.
4. Never invent, machine-translate, copy, or silently omit a target value. If the user explicitly
   authorizes an exact same-string exception, record its exact locales, string, scope, reason, and
   validation; do not call it a translation or extend it to other locales.
5. Preserve placeholders, markup, escape sequences, plural/select variables, and string key
   identity. A translation that breaks the resource contract is incomplete.
6. Missing authoritative copy, ambiguous semantic scope, unsupported locale coverage, or failed
   validation produces `blocked`, not a guessed result.

## Workflow

### 1. Discover the locale contract

Read the project's actual localization configuration and resource directories. Record:

```text
locale | source/config location | enabled or supported | resource format | fallback owner
```

Include locales supplied by build settings, package configuration, server/content configuration,
or platform resource conventions. If two sources disagree, record the conflict and stop.

### 2. Find the semantic copy scope

Search for the requested key, source text, translations, accessibility text, state-specific labels,
plural variants, and hardcoded duplicates. Record the authoritative key and every related entry.
Do not replace every textual occurrence merely because it matches the old words.

Classify each entry as:

- required target in this change;
- existing value that must remain unchanged;
- fallback or system-owned value;
- unrelated occurrence;
- unresolved semantic match.

### 3. Build the locale matrix

For every required locale, record:

```text
locale | key/entry | current value | target value | source of target
      | status | exception/reason | validation
```

Target sources may be the user's exact copy, an approved translation source, an existing
authoritative glossary, or an explicit same-string exception. A missing target source is `blocked`.

For each target, also compare placeholders, markup, variable names, plural categories, line-break
constraints, and accessibility meaning. Locale-specific grammar may change wording, but not the
underlying action or state unless `requirements-closure` explicitly authorizes that change.

### 4. Record same-string exceptions

Treat an exception as data, not an informal note:

```text
exception_id:
source_locale:
exact_string:
affected_locales:
scope:
reason:
explicit_user_authorization:
not_a_translation: true
validation:
```

The exception applies only to the listed locales and semantic key. Do not infer authorization for
other locales, future keys, or future changes. If the user says “temporarily,” record the review
condition or follow-up needed; do not silently make the exception permanent.

### 5. Validate and report

Validate the complete matrix with the project's resource parser, localization test, build check,
or a targeted exact-value script. At minimum verify:

- every required locale/key exists;
- every target value is authoritative or explicitly excepted;
- placeholders and resource syntax remain valid;
- no unintended key, locale, fallback, hardcoded copy, or unrelated state changed;
- same-string exceptions match exactly only where authorized.

Return one status:

- `ready`: complete matrix and validation pass; hand off to `confirm-gate`.
- `blocked`: missing copy, unclear scope, conflicting locale contract, or failed validation.

Use [localization-matrix-template.md](references/localization-matrix-template.md) for the
artifact and report:

```text
Localization status: ready | blocked
Supported locales: ...
Semantic scope: ...
Matrix: <path or table>
Exceptions: ... | none
Validation: ...
Open decisions/blockers: ... | none
Source-edit confirmation: required through confirm-gate
```

## Relationship to other skills

| Skill | Boundary |
|---|---|
| `requirements-closure` | Defines business states, transitions, and state-dependent copy ownership. |
| `api-contract` | Defines API fields and server-driven business meaning. |
| `confirm-gate` | Obtains user approval before source edits. |

## Common mistakes

- **Only the named locale is checked:** enumerate the project's complete locale contract first.
- **Matching words are treated as the same key:** verify semantic ownership and state/context.
- **A missing translation is copied silently:** block or record an explicit same-string exception.
- **Placeholders are changed during translation:** compare variables and markup before approval.
- **Fallback behavior is assumed:** identify the actual fallback owner and validate it.
