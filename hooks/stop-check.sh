#!/usr/bin/env bash
# ABOUTME: Stop hook that blocks premature stopping until TASKMASTER_DONE signal is emitted.
# ABOUTME: Detects the signal in Claude's FINAL MESSAGE ONLY; full protocol lives in the SKILL.md.
set -u

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  SESSION_ID="unknown-session"
fi

# Skip subagents: short transcripts indicate agent tasks, not main sessions
if [ -f "$TRANSCRIPT" ]; then
  LINE_COUNT=$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo "0")
  if [ "$LINE_COUNT" -lt 20 ]; then
    exit 0
  fi
fi

# --- counter ---
COUNTER_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="${COUNTER_DIR}/${SESSION_ID}"
# Finite default: a cost backstop so a stuck loop cannot bill the user forever.
# Set TASKMASTER_MAX=0 to restore unlimited blocking.
MAX=${TASKMASTER_MAX:-20}

COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
fi

# --- signals ---
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
BLOCKED_SIGNAL="TASKMASTER_BLOCKED::${SESSION_ID}"

# Detect signals in CLAUDE'S FINAL MESSAGE ONLY — never scan the raw transcript.
# The block message below echoes DONE_SIGNAL/BLOCKED_SIGNAL, and every block writes
# that message into the transcript. A transcript-wide grep would therefore match the
# hook's own past output and silently disarm the guard after a single block.
FINAL_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if [ -z "$FINAL_MSG" ] && [ -f "$TRANSCRIPT" ]; then
  # Fallback when last_assistant_message is absent: reconstruct the last assistant
  # TEXT block from the transcript tail (assistant role only, text blocks only —
  # never user/system/attachment entries, which is where injected reasons live).
  FINAL_MSG=$(tail -400 "$TRANSCRIPT" 2>/dev/null | jq -Rrs '
    [ split("\n")[]
      | select(length > 0)
      | (fromjson? // empty)
      | select(.type == "assistant")
      | (.message.content // [])[]?
      | select(.type == "text")
      | .text
    ] | last // ""
  ' 2>/dev/null)
fi

# Genuine completion: allow stop and clear the counter.
if printf '%s' "$FINAL_MSG" | grep -Fq "$DONE_SIGNAL" 2>/dev/null; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Honest blocked-exit: a task can genuinely need something only the user can provide
# (a credential, a decision, access Claude cannot obtain). Rather than force Claude to
# loop or lie, accept an explicit blocked signal — but only AFTER >=1 prior block, so it
# must attempt at least one retry first. Logged for audit; does not mean "done".
if [ "$COUNT" -ge 1 ] && printf '%s' "$FINAL_MSG" | grep -Fq "$BLOCKED_SIGNAL" 2>/dev/null; then
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

if [ "$MAX" -gt 0 ]; then
  LABEL="TASKMASTER (${NEXT}/${MAX})"
else
  LABEL="TASKMASTER (${NEXT})"
fi

# Minimal block message — full checklist is in the taskmaster skill. Names both exits
# (done / genuinely-blocked) because the skill body is not guaranteed to be loaded.
# The header matches the completion banner in the skill so both texts share one identity.
HEADER="━━━━━━━━━━━ ◆ ${LABEL} ◆ ━━━━━━━━━━━"
REASON="${HEADER}
Completion signal not found. Re-read the user's original request and verify every item is FULLY done — not started, DONE. Do not narrate remaining work — execute it. When every item is verified done, end your final message with: ${DONE_SIGNAL}. If you are truly blocked on something only the user can provide, ask the user or emit ${BLOCKED_SIGNAL} instead of stopping."

jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
