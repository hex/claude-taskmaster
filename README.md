# claude-taskmaster

Completion guard plugin for Claude Code. Prevents Claude from stopping prematurely by enforcing an explicit done signal before allowing a turn to end.

Inspired by [eyaltoledano/claude-taskmaster](https://github.com/eyaltoledano/claude-taskmaster), rebuilt and optimized for Claude Code's plugin system with a ~90% reduction in hook output (5,094 chars down to ~495 chars per block).

## How It Works

1. **Stop hook** blocks every stop attempt unless a `TASKMASTER_DONE::<session_id>` signal appears at the end of **Claude's final message**, as the last line of the completion banner
2. **Completion protocol skill** provides a 6-point checklist (goal confrontation, request verification, task list, plan verification, error check, blocker resolution) that Claude internalizes through the skill system
3. The hook output is a minimal ~495-char nudge — the heavy lifting is done by the skill description which is always in Claude's context

### What It Looks Like

Completion banner, emitted by Claude when the checklist genuinely passes:

```
━━━━━━━━━━━━━━━━━━━━━━━━━ ◆ ━━━━━━━━━━━━━━━━━━━━━━━━━
           T A S K M A S T E R  ·  D O N E
━━━━━━━━━━━━━━━━━━━━━━━━━ ◆ ━━━━━━━━━━━━━━━━━━━━━━━━━
TASKMASTER_DONE::<session_id>
```

Block message, emitted by the hook when a stop attempt is rejected:

```
━━━━━━━━━━━ ◆ TASKMASTER (1/20) ◆ ━━━━━━━━━━━
Completion signal not found. Re-read the user's original request and ...
```

### Signals

| Signal | Emitted by Claude | Effect |
|--------|-------------------|--------|
| `TASKMASTER_DONE::<session_id>`    | as the last line of the completion banner ending the final message, when the checklist genuinely passes | allow stop, clear counter |
| `TASKMASTER_BLOCKED::<session_id>` | when hard-blocked on something only the user can provide (credential, decision, access) | allow stop **after ≥1 prior block**, logged to `$TMPDIR/taskmaster/blocked.log` |

Detection reads **only Claude's final assistant message**, never the raw transcript — the block message echoes the signal strings into the transcript, so a transcript-wide search would match the hook's own past output and disarm the guard after one block.

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

**Why detect the signal in the final message only?**
Every block writes its reason — which contains the literal signal strings — into the transcript. An earlier version searched the whole transcript tail, so on the *next* block it matched the hook's own prior output and silently allowed the stop: the guard disarmed itself after a single block. Detection now reads only Claude's final assistant message (`last_assistant_message`, or the last assistant text block reconstructed from the transcript), which cannot contain the hook's injected reason. A false block is recoverable; a false allow is silent — so this fails closed.

**Why a blocked-exit token and a finite default cap?**
With unlimited blocking, a Claude that genuinely needs a credential or a user decision it cannot obtain has only two moves: loop forever, or emit a dishonest done signal. `TASKMASTER_BLOCKED::<session_id>` gives it an honest, auditable exit — honored only after at least one real retry, and logged. The finite default `TASKMASTER_MAX=20` is a cost backstop so a stuck loop cannot bill the user indefinitely; set `TASKMASTER_MAX=0` to restore unlimited blocking.

**Why keep the nudge minimal?**
The reactive block message is ~495 chars (~90% below the upstream ~5,094). It names both exits (done and blocked) because the skill body is not guaranteed to be loaded on a given turn — but the detailed checklist stays in the skill, not the per-block output. (An earlier iteration benchmarked a 264-char done-only nudge across 3 scenarios / 19 assertions at 100% pass; the honest blocked-exit was worth the added chars.)

**Why skip subagents?**
Transcripts under 20 lines indicate subagent tasks (tool calls, searches). Blocking these would prevent agent parallelism from working. (Note: line count is a coarse proxy — a short main session is skipped and a long subagent is not; a more robust subagent signal is a known follow-up.)

## License

MIT
