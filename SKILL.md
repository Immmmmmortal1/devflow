---
name: dev-flow
description: Use when the user wants to plan feature development or bug fixes before implementation in this workspace. Trigger on requests like "开发这个功能", "先分析方案", "排查这个 bug", or "先别改代码". For feature work, require gstack-review for impact analysis and execution planning. For bug work, require gstack-investigate for root cause analysis, then gstack-review for the change plan. Do not modify code until the user confirms the proposed plan, and after implementation use git-commit-convention only after the user confirms the commit.
---

# Dev Flow

## Overview

This skill forces a planning-first workflow before code changes. It separates feature work from bug work, uses the right gstack skill for each, and stops before implementation until the user explicitly confirms.

After implementation is done, it also forces a commit step that must use `git-commit-convention`, and that commit must wait for an explicit user confirmation.

For bug-fix work, the commit step has an additional hard boundary:
- the concrete ZenTao bug id must be confirmed before commit
- the matching bug must be marked resolved in ZenTao before the commit is created

## Request Classification

Start by classifying the request into one of two paths:

- **Feature development**
  Use this path when the user is asking to add, change, extend, optimize, redesign, or refactor a capability.
- **Bug fix**
  Use this path when the user is asking why something is broken, unexpected, regressed, clickable when it should not be, crashing, or behaving incorrectly.

If the request contains both a bug and a feature change, treat it as a bug first. Find the root cause before proposing expansion work.

## Feature Workflow

For feature development requests, always do this in order:

1. Use `gstack-review` first.
2. Use that review to analyze:
   - the requirement understanding
   - affected files and modules
   - likely user-facing impact
   - regression risk
   - missing dependencies, tests, or validation steps
3. Produce an execution plan before writing code.
4. Stop and present the plan to the user.
5. Wait for explicit confirmation before implementation.

The execution plan should be concrete. Name the files, the change areas, the validation path, and any risk or uncertainty.

## Bug Workflow

For bug-fix requests, always do this in order:

1. Use `gstack-investigate` first.
2. Find and state the root cause.
3. After root cause analysis, use `gstack-review`.
4. Use that review to propose the modification plan:
   - what should change
   - why that change fixes the root cause
   - what side effects to watch for
   - what test or reproduction path should verify the fix
5. Stop and present the plan to the user.
6. Wait for explicit confirmation before implementation.

Do not jump from symptom to code edit. Investigation first, review second, implementation only after confirmation.

## Confirmation Gate

Before changing any source file, provide a short decision-ready summary and wait for the user to confirm.

Use this structure:

- `Type:` feature or bug
- `Analysis tool used:` `gstack-review` or `gstack-investigate -> gstack-review`
- `Root cause:` only for bugs
- `Files likely to change:`
- `Plan:`
- `Validation:`
- `Need user confirmation before coding: yes`

If the user says to proceed, implementation may begin. If the user asks for adjustments, revise the plan first and ask again.

## Commit Gate

After implementation and validation are complete, do not commit immediately.

Use this flow:

1. Summarize what was implemented and how it was validated.
2. Ask the user whether to create the commit now.
3. If the work is a bug fix, confirm the exact ZenTao bug id before proceeding.
4. If the user confirms and the work is a bug fix, mark that ZenTao bug as resolved before creating the commit.
5. Only after ZenTao is updated, invoke `git-commit-convention`.
6. Use `git-commit-convention` to inspect the diff, decide the correct commit type, and create the commit message.
7. Only then create the commit.

If the user does not confirm, stop with the code changes uncommitted.

If the work is a bug fix and the ZenTao bug id is missing, ambiguous, or the ZenTao resolve action fails, stop and do not create the commit.

## Hard Rules

Follow these rules every time this skill is used:

1. Do not modify code during the analysis phase.
2. Do not skip `gstack-review` for feature work.
3. Do not skip `gstack-investigate` for bug work.
4. Do not propose implementation before stating the analysis result.
5. Do not start editing until the user confirms the plan.
6. Do not create a commit until the user confirms the commit step.
7. When committing completed work, always use `git-commit-convention`.
8. When the completed work is a bug fix, do not commit until the exact ZenTao bug id is confirmed.
9. When the completed work is a bug fix, mark the matching ZenTao bug as resolved before creating the commit.
10. If ZenTao resolution fails or the bug mapping is unclear, stop and ask the user instead of guessing.

## Example Triggers

Use this skill when the user says things like:

- "先分析这个功能怎么改"
- "先看改动影响，再给我方案"
- "这个 bug 为什么会这样，先排查"
- "不要直接改代码，先出方案"
- "先 review 一下这个需求怎么做"

## Not For

Do not use this skill when:

- the user explicitly wants immediate coding and has already approved the implementation direction
- the request is only to explain existing code
- the request is a pure code review with no implementation planning step
