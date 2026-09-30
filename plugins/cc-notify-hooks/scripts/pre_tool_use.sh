#!/usr/bin/env bash
#
# Question-tool PreToolUse dispatcher (shared by Codex / Reasonix / dsh)
# request_user_input (Codex) and ask / AskUserQuestion (Reasonix/dsh) trigger a waiting notification;
# every other tool keeps the existing pending-clearing behavior.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVENT_DATA=$(cat 2>/dev/null || true)

[ -n "$EVENT_DATA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$EVENT_DATA" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$EVENT_DATA" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$TOOL_NAME" in
    request_user_input|ask|AskUserQuestion)
        QUESTION_COUNT=$(printf '%s' "$EVENT_DATA" | jq -r '
            if (.tool_input.questions? | type) == "array"
            then (.tool_input.questions | length)
            else 0
            end
        ' 2>/dev/null || echo "0")

        [ "$QUESTION_COUNT" -gt 0 ] 2>/dev/null || exit 0
        printf '%s' "$EVENT_DATA" \
            | bash "${SCRIPT_DIR}/notify.sh" notification user_input \
            || true
        ;;
    *)
        printf '%s' "$EVENT_DATA" \
            | bash "${SCRIPT_DIR}/clear_pending.sh" \
            || true
        ;;
esac

exit 0
