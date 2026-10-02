#!/usr/bin/env bash
#
# Question-tool PreToolUse dispatcher (shared by Codex / Reasonix / dsh)
# request_user_input (Codex) and ask / AskUserQuestion (Reasonix/dsh) trigger a waiting
# notification. request_user_input_async triggers one only for a payload that mirrors the
# current Codex handler contract (validated below), because the handler rejects invalid
# arguments after PreToolUse has already run. Every other tool keeps the existing
# pending-clearing behavior.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVENT_DATA=$(cat 2>/dev/null || true)

[ -n "$EVENT_DATA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$EVENT_DATA" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$EVENT_DATA" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$TOOL_NAME" in
    request_user_input_async)
        # Codex validates the async tool's arguments only after PreToolUse runs,
        # so mirror the current handler contract before notifying: an invalid
        # payload is rejected later, the user never sees a question, and no
        # pending state may be created. The tool is still recognized, so an
        # invalid payload must stay quiet instead of falling through to the
        # ordinary-tool clear behavior.
        ASYNC_VALID=$(printf '%s' "$EVENT_DATA" | jq -r '
            def blank_string:
                if (type == "string") then ((gsub("[[:space:]]"; "") | length) == 0) else false end;
            def valid_option:
                if (type != "string") then false
                elif (blank_string) then false
                else true end;
            def valid_question:
                if (type != "object") then false
                elif ((keys_unsorted - ["title", "options"]) | length) != 0 then false
                elif ((.title | type) != "string") then false
                elif (.title | blank_string) then false
                elif (has("options") | not) then true
                elif (.options == null) then true
                elif ((.options | type) != "array") then false
                elif ((.options | length) < 1) then false
                else ([.options[] | valid_option] | all)
                end;
            if (.tool_input.questions? | type) != "array" then false
            elif (.tool_input.questions | length) < 1 then false
            else all(.tool_input.questions[]; valid_question)
            end
        ' 2>/dev/null || echo "false")
        [ "$ASYNC_VALID" = "true" ] || exit 0
        printf '%s' "$EVENT_DATA" \
            | bash "${SCRIPT_DIR}/notify.sh" notification user_input \
            || true
        ;;
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
