#!/usr/bin/env bash
#
# Codex PreToolUse dispatcher
# request_user_input 触发等待通知，其他工具维持原有 pending 清理行为。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVENT_DATA=$(cat 2>/dev/null || true)

[ -n "$EVENT_DATA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$EVENT_DATA" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$EVENT_DATA" | jq -r '.tool_name // empty' 2>/dev/null || true)

if [ "$TOOL_NAME" = "request_user_input" ]; then
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
else
    printf '%s' "$EVENT_DATA" \
        | bash "${SCRIPT_DIR}/clear_pending.sh" \
        || true
fi

exit 0
