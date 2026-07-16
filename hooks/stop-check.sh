#!/usr/bin/env bash
# ABOUTME: Stop hook that blocks premature stopping until TASKMASTER_DONE signal is emitted.
# ABOUTME: Detects the signal as the LAST LINE of Claude's final message; protocol lives in SKILL.md.
set -u

INPUT=$(cat)

# jq is a hard dependency (session id, message parsing, block emission all use it).
# If it is missing the plugin is misinstalled — fail CLOSED with an actionable block
# rather than silently no-op, which would let every stop through undetected.
if ! command -v jq >/dev/null 2>&1; then
  printf '{"decision":"block","reason":"taskmaster: jq not found on PATH — cannot verify completion. Install jq or remove the taskmaster Stop hook."}\n'
  exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  SESSION_ID="unknown-session"
fi

# Skip subagents: short transcripts indicate agent tasks, not main sessions. Only skip
# when wc actually SUCCEEDS — an unreadable transcript must fall through and block, not
# be mistaken for a short one (a failed read would otherwise fail open).
if [ -f "$TRANSCRIPT" ]; then
  if LINE_COUNT=$(wc -l < "$TRANSCRIPT" 2>/dev/null); then
    LINE_COUNT=${LINE_COUNT//[[:space:]]/}
    if [ "${LINE_COUNT:-0}" -lt 20 ]; then
      exit 0
    fi
  fi
fi

# --- counter ---
# Per-user dir avoids a cross-user collision on Linux's shared /tmp (another user owning
# /tmp/taskmaster would make the counter write fail and block forever). macOS $TMPDIR is
# already per-user, so this only changes the /tmp fallback path.
COUNTER_DIR="${TMPDIR:-/tmp}/taskmaster-$(id -u)"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="${COUNTER_DIR}/${SESSION_ID}"
# Finite default: a cost backstop so a stuck loop cannot bill the user forever.
# Set TASKMASTER_MAX=0 to restore unlimited blocking.
MAX=${TASKMASTER_MAX:-20}
case "$MAX" in ''|*[!0-9]*) MAX=20 ;; esac

COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
fi
# Non-numeric counter (interrupted write, race, tamper) would abort arithmetic below under
# set -u and fail open. Sanitize to 0 so a corrupt counter re-arms instead of disarming.
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac

# --- signals ---
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
BLOCKED_SIGNAL="TASKMASTER_BLOCKED::${SESSION_ID}"

# Detect signals in CLAUDE'S FINAL MESSAGE ONLY — never scan the raw transcript.
# The block message below echoes DONE_SIGNAL/BLOCKED_SIGNAL, and every block writes
# that message into the transcript. A transcript-wide grep would therefore match the
# hook's own past output and silently disarm the guard after a single block.
FINAL_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if [ -z "$FINAL_MSG" ] && [ -f "$TRANSCRIPT" ]; then
  # Fallback when last_assistant_message is absent (e.g. the turn ends on a tool_use with
  # no text block): reconstruct the last assistant TEXT block — but only from entries
  # AFTER the last user turn, so a genuine DONE from a PREVIOUS, already-finished turn
  # cannot be mistaken for this turn's completion.
  FINAL_MSG=$(tail -400 "$TRANSCRIPT" 2>/dev/null | jq -Rrs '
    [ split("\n")[] | select(length > 0) | (fromjson? // empty) ] as $e
    | ($e | map(.type) | rindex("user")) as $u
    | [ $e[ (($u // -1) + 1): ][]
        | select(.type == "assistant")
        | (.message.content // [])[]?
        | select(.type == "text")
        | .text
      ] | last // ""
  ' 2>/dev/null)
fi

# The signal is authoritative only as the LAST non-empty line of the final message — not
# anywhere in it. A substring match would disarm the guard whenever Claude merely quotes
# the signal, shows it in an example, or narrates it mid-task. Compare the trimmed last
# non-empty line exactly.
LAST_LINE=$(printf '%s' "$FINAL_MSG" | tr -d '\r' \
  | awk '{sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")} $0 != "" {l=$0} END {print l}')

# Genuine completion: allow stop and clear the counter.
if [ "$LAST_LINE" = "$DONE_SIGNAL" ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Honest blocked-exit: a task can genuinely need something only the user can provide
# (a credential, a decision, access Claude cannot obtain). Rather than force Claude to
# loop or lie, accept an explicit blocked signal — but only AFTER >=1 prior block, so it
# must attempt at least one retry first. Logged for audit; does not mean "done".
if [ "$COUNT" -ge 1 ] && [ "$LAST_LINE" = "$BLOCKED_SIGNAL" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${SESSION_ID} blocked-exit after ${COUNT} block(s)" \
    >> "${COUNTER_DIR}/blocked.log" 2>/dev/null || true
  rm -f "$COUNTER_FILE"
  exit 0
fi

NEXT=$((COUNT + 1))
echo "$NEXT" > "$COUNTER_FILE"

# Escape hatch: allow stop after MAX blocks (cost backstop; MAX=0 disables it).
if [ "$MAX" -gt 0 ] && [ "$NEXT" -ge "$MAX" ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Block label shows how many times we've re-anchored this session. It deliberately omits
# MAX so the exact number of attempts that would release the guard is not advertised.
LABEL="TASKMASTER (${NEXT})"

# Minimal block message — full checklist is in the taskmaster skill. Names both exits
# (done / genuinely-blocked) because the skill body is not guaranteed to be loaded.
# The header matches the completion banner in the skill so both texts share one identity.
HEADER="━━━━━━━━━━━ ◆ ${LABEL} ◆ ━━━━━━━━━━━"
REASON="${HEADER}
Completion signal not found. Re-read the user's original request and verify every item is FULLY done — not started, DONE. Do not narrate remaining work — execute it. When every item is verified done, end your final message with this exact line (copy the session id from this message): ${DONE_SIGNAL}. If you need something only the user can provide, ask via the AskUserQuestion tool (ending your turn to ask will be blocked); if you have tried and are hard-blocked, end your final message with ${BLOCKED_SIGNAL}."

jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
