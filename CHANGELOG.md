# Changelog

All notable changes to claude-taskmaster are documented here.

## 2026.7.2

Adversarial-review hardening pass (cross-vendor council + three red-team lenses). Closes several fail-open paths, tightens signal detection, and adds a completion banner. The plugin is now documented honestly as an attestation aid, not a verifier.

### Features
- **Completion banner and matching block header.** The done signal is emitted as the last line of a heavy-rule `T A S K M A S T E R · D O N E` banner, and the block message opens with a matching `◆` header, giving both texts one visual identity.

### Fixes
- **Substring bypass (high).** Detection matched the signal *anywhere* in the final message via `grep -Fq`, so a quoted, code-fenced, or narrated copy of the signal disarmed the guard mid-task. It now matches the **exact last non-empty line** — the banner is emitted bare (not in a code fence) so the signal is genuinely the final line.
- **Corrupt-counter fail-open (high).** A non-numeric counter file aborted the script under `set -u` before it could emit a block, silently allowing the stop *and* leaving the corrupt value in place so every later stop that session also failed open. The counter and `TASKMASTER_MAX` are now validated numeric (bad values reset), fixing both this and the silent loss of the cost backstop on a mistyped `MAX`.
- **Missing-`jq` and unreadable-transcript fail-opens (medium).** A missing `jq` binary silently disabled the whole hook; an existing-but-unreadable transcript was misread as a short subagent transcript and skipped. Both now fail closed (block).
- **Stale prior-turn signal (medium).** When a turn ended on a tool call (empty `last_assistant_message`), the transcript fallback could reconstruct a *previous*, already-finished turn's done signal and allow the stop. The fallback is now scoped to assistant text after the last user turn.
- **Cross-user `/tmp` collision (medium, Linux).** The counter dir is now per-user (`taskmaster-<uid>`), so another user owning `/tmp/taskmaster` can no longer make the counter write fail and block forever.

### Docs / prompt
- Block message points at the **AskUserQuestion tool** (ending a turn to ask was itself blocked, causing a loop) and tells Claude to copy the session id from the block message (it has no other reliable source before the first block). The block label drops `/MAX` so the exact release threshold is not advertised.
- README: corrected the overstated "honored only after at least one real retry" (a block is not a retry — the gate is `≥1 block`, and the two-approaches bar is honor-system); added a **"What it deliberately does NOT do"** section; documented the subagent-skip fail-open and the per-streak nature of `MAX`. Block message ~495 → ~635 chars (~88% below the upstream baseline).

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
