# claude-taskmaster

Completion guard plugin for Claude Code. Prevents Claude from stopping prematurely by enforcing an explicit done signal before allowing a session to end.

Inspired by [eyaltoledano/claude-taskmaster](https://github.com/eyaltoledano/claude-taskmaster), rebuilt and optimized for Claude Code's plugin system with a 94% reduction in hook output (5,094 chars down to 264 chars per block).

## How It Works

1. **Stop hook** blocks every stop attempt unless a `TASKMASTER_DONE::<session_id>` signal is found in the conversation
2. **Completion protocol skill** provides a 6-point checklist (goal confrontation, request verification, task list, plan verification, error check, blocker resolution) that Claude internalizes through the skill system
3. The hook output is a minimal 4-line nudge (~264 chars) — the heavy lifting is done by the skill description which is always in Claude's context

### Signal Flow

```
Claude tries to stop
    |
    v
Stop hook fires (stop-check.sh)
    |
    +-- TASKMASTER_DONE::<session_id> found? --> allow stop
    |
    +-- Subagent (transcript < 20 lines)? ----> allow stop
    |
    +-- TASKMASTER_MAX reached? --------------> allow stop
    |
    +-- Otherwise: block with 4-line message
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
| `TASKMASTER_MAX`    | `0`     | Max stop-blocks before allowing stop. `0` = unlimited (keeps blocking until done signal). |

Set in your shell profile or per-session:

```bash
export TASKMASTER_MAX=5  # allow stop after 5 blocks
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
The original taskmaster injects the entire compliance prompt (~5K chars, 32 lines) on every block. This works for stateless agents like Codex but creates screen spam in Claude Code. Skills provide persistent context — the description (~100 words) is always loaded, so the hook only needs a brief nudge to re-anchor Claude's attention.

**Why 4 lines instead of 8?**
Benchmarked both variants across 3 scenarios with 19 assertions. Both achieved 100% pass rate. The 4-line version uses 44% less output with equivalent effectiveness.

**Why skip subagents?**
Transcripts under 20 lines indicate subagent tasks (tool calls, searches). Blocking these would prevent agent parallelism from working.

## License

MIT
