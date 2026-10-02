#!/usr/bin/env bash
#
# Clear the notifications queued for the current session.
# With no argument (UserPromptSubmit) it clears every pending marker for the current
# session and ends any async-question waiting state; with an event kind it clears only
# that category. Internal modes: --tool-activity keeps a live async Reply-needed
# delivery pending alive while ordinary tool activity clears other kinds;
# --async-end ends the async waiting state without touching pending markers.

STATE_BASE="${PLUGIN_DATA:-${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/hooks}}"
STATE_DIR="${CC_NOTIFY_STATE_DIR:-${STATE_BASE}/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

EVENT_DATA=$(cat 2>/dev/null || true)
[ -n "$EVENT_DATA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$EVENT_DATA" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

safe_state_key() {
    local value="${1:-unknown}"
    value=$(printf '%s' "$value" | LC_ALL=C tr -c '[:alnum:]_.-' '_' | cut -c1-96)
    printf '%s' "${value:-unknown}"
}

HOOK_EVENT=$(printf '%s' "$EVENT_DATA" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$EVENT_DATA" | jq -r '.session_id // empty' 2>/dev/null || true)
TURN_ID=$(printf '%s' "$EVENT_DATA" | jq -r '.turn_id // empty' 2>/dev/null || true)
SESSION_KEY=$(safe_state_key "${SESSION_ID:-${TURN_ID:-unknown}}")
CLEAR_KIND="${1:-}"

if [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
    MESSAGE=$(printf '%s' "$EVENT_DATA" | jq -r '.message // .prompt // empty' 2>/dev/null || true)
    if [[ "$MESSAGE" =~ ^[[:space:]]*/exit[[:space:]]*$ ]]; then
        touch "${STATE_DIR}/exiting_${SESSION_KEY}"
    else
        rm -f "${STATE_DIR}/exiting_${SESSION_KEY}" 2>/dev/null || true
    fi
fi

if [ "$CLEAR_KIND" = "--tool-activity" ]; then
    # Ordinary tool activity while an async question waits is not a user answer:
    # the Reply-needed user_input delivery pending must survive any tool call.
    if compgen -G "${STATE_DIR}/awaiting_async_${SESSION_KEY}_*" >/dev/null 2>&1; then
        while IFS= read -r pending_file; do
            case "$pending_file" in
                */"pending_${SESSION_KEY}_user_input_"*) continue ;;
            esac
            rm -f "$pending_file" 2>/dev/null || true
        done < <(compgen -G "${STATE_DIR}/pending_${SESSION_KEY}_*" || true)
    else
        rm -f "${STATE_DIR}/pending_${SESSION_KEY}_"* 2>/dev/null || true
    fi
elif [ "$CLEAR_KIND" = "--async-end" ]; then
    rm -f "${STATE_DIR}/awaiting_async_${SESSION_KEY}_"* 2>/dev/null || true
elif [ -n "$CLEAR_KIND" ]; then
    KIND_KEY=$(safe_state_key "$CLEAR_KIND")
    rm -f "${STATE_DIR}/pending_${SESSION_KEY}_${KIND_KEY}_"* 2>/dev/null || true
else
    # The answer to an async question arrives as user input: UserPromptSubmit is
    # the authoritative end of async waiting for this session.
    rm -f "${STATE_DIR}/awaiting_async_${SESSION_KEY}_"* 2>/dev/null || true
    rm -f "${STATE_DIR}/pending_${SESSION_KEY}_"* 2>/dev/null || true
fi

exit 0
