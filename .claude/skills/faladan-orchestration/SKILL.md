---
name: faladan-orchestration
description: Use when running as Opus on any non-trivial FalaDan work — planning changes, executing implementation plans, reviewing subagent output, or pausing for human input. Opus plans and reviews; Sonnet subagents execute.
---

# FalaDan Orchestration

## Overview

Opus plans, supervises, and reviews. Sonnet subagents execute. The point is not to conserve a
metered resource — it is that **a weaker executor succeeds only when the task is shaped for
it**. Spend Opus on judgment: decomposition, review, and the small set of changes that are
genuinely unsafe to delegate. Spend Sonnet on bounded, verifiable execution.

Ported from Dan's `fable-token-efficiency` skill in PeritoX, retargeted one tier down. Fable is
not in the loop here; treat it as a manual escalation Dan invokes himself.

## The Rules

### 1. Shape every task for the executor

A task is ready to delegate only when it carries all six:

- **File allowlist** — the exact files that may change
- **Do-not-touch list** — the neighbours most likely to get dragged in
- **Executor tag** — `sonnet-alone` or `opus-supervised`
- **The test, written first**, as literal code wherever possible
- **One verification command** — always `./Scripts/verify.sh`, plus any task-specific check
- **"Done means…"** — a checkable statement, never "make it work"

Scope to roughly ≤3 files and ≤150 changed lines, so the whole relevant context fits
comfortably in a fresh subagent.

If you cannot write the test first, the task is not understood well enough to delegate. Split
it or take it `opus-supervised`.

### 2. `opus-supervised` work is never delegated

Anything touching the **CGEvent tap**, the **Accessibility paste path**, or
**`PasteboardService`**. A subtly wrong change there silently breaks system-wide text input,
and no automated test catches it. Execute these in the orchestrator context.

Everything else defaults to `sonnet-alone`. "It's faster if I just do it myself" is the waste,
not the shortcut.

### 3. Delegate with an explicit stop-rather-than-guess instruction

Spawn via the Agent tool with `model: "sonnet"`, and instruct each subagent verbatim:

> "Perform only work you can fully evaluate and understand. If anything is ambiguous or beyond
> confident evaluation, stop and return it rather than guessing. Do not expand scope beyond the
> file allowlist."

This matters more here than in the Fable/Opus version — the capability gap is wider.

### 4. Verify every return; take pushback seriously

Run `./Scripts/verify.sh` on every subagent return. Never hand-compose the build/test commands,
and never accept a subagent's claim of success without running the gate yourself.

A subagent pushing back on the plan is a **feature**. Verify the claim before dismissing it —
a weaker model that noticed a real problem has found something the plan got wrong.

### 5. Review before moving on

Review each completed task via `superpowers:requesting-code-review` before starting the next.
Reviewing a clean bounded diff is the entire reason tasks are kept small.

## Usage-limit fallback ladder

When a subagent dies on a usage limit — returns ~0 tokens, "stalled", or an empty result — do
**not** ask Dan to switch models by hand:

1. **Check `git status` first.** Partial work is often already on disk. A blind redispatch
   either wastes tokens or clobbers progress.
2. **Resume vs. restart.** If the agent still holds context, resume it via `SendMessage`. If it
   returned nothing and holds no context, start fresh.
3. **Step down a tier** rather than stopping, and note which model you fell back to.

## HANDOFF.md

Write or update `HANDOFF.md` at the project root **before ending any turn** that is blocked on
Dan or stops mid-plan:

- Current state: what was done, what was verified, and with what command
- Plan status: which tasks are done, in progress, pending
- Open decisions for Dan, each with a recommendation
- Exact next steps, such that a **fresh session can resume from HANDOFF.md alone**

This is what makes clearing context between phases cheap.

## Human checkpoints

Three things no automated check reaches. Ask Dan; never claim them yourself.

1. Hold-to-talk start/stop timing *feels* right
2. The indicator appears and always disappears, including on the sub-threshold discard path
3. Text actually lands in a third-party app

## Quick Reference

| Situation | Action |
|---|---|
| Writing a plan | Six fields per task; ≤3 files, ≤150 lines |
| Can't write the test first | Task isn't understood — split it or take it `opus-supervised` |
| CGEvent tap / paste path / `PasteboardService` | `opus-supervised`; execute in orchestrator context |
| Any other task | Delegate to a Sonnet subagent — this is the default |
| Subagent returned | Run `./Scripts/verify.sh`, then `requesting-code-review` |
| Subagent pushed back | Verify the claim; don't dismiss it |
| Subagent killed by a usage limit | `git status` → resume or restart → step down a tier |
| Blocked on Dan / ending mid-plan | Write `HANDOFF.md` first |

## Red Flags

- Delegating a task whose test you couldn't write first
- Accepting "tests pass" without running `./Scripts/verify.sh` yourself
- Hand-composing `swift test` instead of using the gate
- Letting a subagent edit outside its file allowlist
- Claiming a human-checkpoint item (timing, indicator, paste) is verified
- Ending a blocked turn without `HANDOFF.md`
