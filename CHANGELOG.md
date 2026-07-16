# Changelog

All notable changes to claude-taskmaster are documented here.

## Unreleased

### Features
- **Completion banner and block header.** The done signal is now emitted as the last line of a heavy-rule `T A S K M A S T E R · D O N E` banner, and the hook's block message opens with a matching `◆` header, giving both taskmaster texts one visual identity. Detection is unchanged — still a substring match on the final assistant message — the banner is presentation only. Block message grows from ~470 to ~495 chars.

## 2026.7.1

Hardening release for the completion guard. Fixes a verified fail-open bug and adds an honest exit for genuinely-blocked sessions. First git-tagged release.

### Fixes
- **Fail-open self-disarm (critical).** The Stop hook scanned the whole transcript tail for the done signal — but the block message the hook injects on every block echoes the literal `TASKMASTER_DONE::<session_id>` string into that transcript. After a single block, the guard matched its own past output and silently allowed the stop. Detection now reads only Claude's final assistant message, so it cannot match the injected reason. Fails closed.

### Features
- **Honest blocked-exit token** — `TASKMASTER_BLOCKED::<session_id>` lets a Claude that genuinely needs something only the user can provide (a credential, a decision, access it cannot obtain) exit without looping or faking completion. Honored only after at least one real retry, and logged to `$TMPDIR/taskmaster/blocked.log`.
- **Finite default `TASKMASTER_MAX=20`** as a cost backstop so a stuck loop cannot bill indefinitely. Set `TASKMASTER_MAX=0` to restore unlimited blocking.

### Docs
- Completion-protocol skill rewritten: per-turn contract with explicit signal placement and an emission-as-attestation framing; USER PRIORITY promoted to the first Critical Rule; user-override guidance added to the always-loaded description; AskUserQuestion + blocked-exit guidance in Blocker Resolution; removed the "you have the internet" overclaim; diversified examples; Configuration moved to README.
- README documents the new detection behavior, the `BLOCKED` token, and the finite `MAX` default, with honest hook-output sizing (~470 chars, ~91% below the upstream baseline).

**Full Changelog**: https://github.com/hex/claude-taskmaster/commits/v2026.7.1
