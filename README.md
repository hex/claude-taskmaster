# claude-taskmaster

Completion guard plugin for Claude Code. Prevents Claude from stopping prematurely by enforcing an explicit done signal before allowing a turn to end.

Inspired by [eyaltoledano/claude-taskmaster](https://github.com/eyaltoledano/claude-taskmaster), rebuilt and optimized for Claude Code's plugin system with a ~88% reduction in hook output (5,094 chars down to ~635 chars per block).

> **What this is — and isn't.** This is a completion *attestation* aid, not a completion *verifier*. It checks that Claude printed a done signal as the last line of its final message; it does not run your tests or inspect your diff. It raises friction against premature stopping for an honest-but-hasty model — it cannot stop a model that is determined to game it (anything with shell access can disable a client-side hook). Treat it as a behavioral brake, not a guarantee. See [What it deliberately does NOT do](#what-it-deliberately-does-not-do).

## How It Works

1. **Stop hook** blocks every stop attempt unless a `TASKMASTER_DONE::<session_id>` signal is the **exact last non-empty line of Claude's final message** (the last line of the completion banner). Matching the last line — not a substring anywhere — is what stops a quoted or narrated copy of the signal from disarming the guard mid-task
2. **Completion protocol skill** provides a 6-point checklist (goal confrontation, request verification, task list, plan verification, error check, blocker resolution) that Claude internalizes through the skill system
3. The hook output is a minimal ~635-char nudge — the heavy lifting is done by the skill description which is always in Claude's context

### What It Looks Like

Completion banner, emitted by Claude when the checklist genuinely passes. It is written as plain text (not fenced) so the signal is the literal last line of the message:

```
━━━━━━━━━━━━━━━━━━━━━━━━━ ◆ ━━━━━━━━━━━━━━━━━━━━━━━━━
           T A S K M A S T E R  ·  D O N E
━━━━━━━━━━━━━━━━━━━━━━━━━ ◆ ━━━━━━━━━━━━━━━━━━━━━━━━━
TASKMASTER_DONE::<session_id>
```

Block message, emitted by the hook when a stop attempt is rejected. The label omits the max so the exact number of attempts that would release the guard is not advertised:

```
━━━━━━━━━━━ ◆ TASKMASTER (1) ◆ ━━━━━━━━━━━
Completion signal not found. Re-read the user's original request and ...
```

### Signals

| Signal | Emitted by Claude | Effect |
|--------|-------------------|--------|
| `TASKMASTER_DONE::<session_id>`    | as the exact last line of the final message, when the checklist genuinely passes | allow stop, clear counter |
| `TASKMASTER_BLOCKED::<session_id>` | when hard-blocked on something only the user can provide (credential, decision, access) | allow stop **after ≥1 prior block**, logged to `$TMPDIR/taskmaster-<uid>/blocked.log` |

Detection reads **only Claude's final assistant message**, never the raw transcript — the block message echoes the signal strings into the transcript, so a transcript-wide search would match the hook's own past output and disarm the guard after one block. Within that message, the signal must be the **exact last non-empty line**, not merely present somewhere.

The `BLOCKED` gate is `≥1 prior block` — note that a block is not proof of a genuine retry. The "attempt at least two distinct approaches first" bar lives in the skill and is honor-system; the hook cannot enforce it.

### Signal Flow

```
Claude tries to stop
    |
    v
Stop hook fires (stop-check.sh)
    |
    +-- Subagent (transcript < 20 lines)? -------------> allow stop
    |
    +-- TASKMASTER_DONE in final message? -------------> allow stop
    |
    +-- TASKMASTER_BLOCKED in final message (count≥1)? -> allow stop (logged)
    |
    +-- TASKMASTER_MAX reached? -----------------------> allow stop
    |
    +-- Otherwise: block with a brief nudge
```

## Installation

### From marketplace

```bash
claude plugin add hex/claude-taskmaster
```

### Manual (local development)

```bash
claude --plugin-dir /path/to/claude-taskmaster
```

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `TASKMASTER_MAX`    | `20`    | Max stop-blocks before allowing stop, as a cost backstop. Set `0` for unlimited (block until a done/blocked signal is emitted). |

Set in your shell profile or per-session:

```bash
export TASKMASTER_MAX=5   # allow stop after 5 blocks
export TASKMASTER_MAX=0   # unlimited (previous default)
```

## Components

| Component | Path | Purpose |
|-----------|------|---------|
| Plugin manifest | `.claude-plugin/plugin.json` | Identity, version, keywords |
| Stop hook config | `hooks/hooks.json` | Registers the Stop event handler |
| Stop hook script | `hooks/stop-check.sh` | Signal detection, counter, block/allow logic |
| Completion skill | `skills/completion-protocol/SKILL.md` | 6-point completion checklist |

## Design Decisions

**Why a skill + hook instead of just a hook?**
The original taskmaster injects the entire compliance prompt (~5K chars, 32 lines) on every block. This works for stateless agents like Codex but creates screen spam in Claude Code. Skills provide persistent context — the description (~130 words) is always loaded, so the hook only needs a brief nudge to re-anchor Claude's attention.

**Why detect the signal in the final message only, as the last line?**
Every block writes its reason — which contains the literal signal strings — into the transcript. An earlier version searched the whole transcript tail, so on the *next* block it matched the hook's own prior output and silently allowed the stop: the guard disarmed itself after a single block. Detection now reads only Claude's final assistant message (`last_assistant_message`, or the last assistant text block reconstructed from the transcript *after the last user turn*, so a previous turn's genuine signal can't leak in either). And within that message it matches the **exact last non-empty line**, not any substring — otherwise Claude quoting, narrating, or showing an example of the signal would disarm the guard mid-task. A false block is recoverable; a false allow is silent — so every ambiguous branch (corrupt counter, unreadable transcript, missing `jq`) is resolved toward blocking.

**Why a blocked-exit token and a finite default cap?**
With unlimited blocking, a Claude that genuinely needs a credential or a user decision it cannot obtain has only two moves: loop forever, or emit a dishonest done signal. `TASKMASTER_BLOCKED::<session_id>` gives it an honest, auditable exit — honored only after ≥1 prior block, and logged. Note this is trust-based: a block is not proof of a genuine retry attempt, and the hook cannot verify that Claude actually tried two approaches (that bar lives in the skill). The finite default `TASKMASTER_MAX=20` is a cost backstop so a stuck loop cannot bill the user indefinitely; set `TASKMASTER_MAX=0` to restore unlimited blocking.

**Why keep the nudge minimal?**
The reactive block message is ~635 chars (~88% below the upstream ~5,094). It names both exits (done and blocked) and points at the AskUserQuestion tool, because the skill body is not guaranteed to be loaded on a given turn — but the detailed checklist stays in the skill, not the per-block output.

**Why skip subagents?**
Transcripts under 20 lines indicate subagent tasks (tool calls, searches). Blocking these would prevent agent parallelism from working. The line count is a coarse proxy — a short main session is skipped (a fresh first turn can fall under the guard) and a long subagent is not; a more robust subagent signal is a known follow-up. The skip only fires when the line count is actually readable: an existing-but-unreadable transcript falls through and blocks rather than being mistaken for a short one.

## What it deliberately does NOT do

These are conscious non-goals, not gaps. The plugin's value is being near-zero-cost and drop-in; the alternatives below trade that away to chase a threat a client-side hook cannot win.

- **It does not verify your work.** It never runs tests, lints, builds, or diffs. It checks that Claude *attested* completion, not that completion happened. If you want a real gate, add PreToolUse/PostToolUse hooks that run your test suite — this plugin is complementary to that, not a substitute.
- **It is not tamper-proof.** Anything with shell access (including Claude) can `chmod -x` the hook or edit the counter. Hardening against a determined local adversary is out of scope; the design target is an honest-but-hasty model taking the cheapest path, not a sabotaging one.
- **It does not require a structured completion payload.** A JSON schema of goal/tests/errors was considered and declined — it raises audit quality but still cannot prove truth, and it adds friction to every single turn.
- **`TASKMASTER_MAX` is per-streak, not a hard per-session ceiling.** The counter clears on each escape, so a never-completing session is released roughly every `MAX` blocks rather than once total. It is a cost backstop, not a completion guarantee.

## License

MIT
