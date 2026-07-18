#!/usr/bin/env bash

notify_has_event_json() {
    local event_json="${1:-}"
    [ -n "$event_json" ] && printf '%s' "$event_json" | jq -e '.schema_version == 1' >/dev/null 2>&1
}

notify_long_note() {
    local event_json="$1"
    printf '%s' "$event_json" | jq -r '
        [.model, .cwd, .hostname]
        | map(select(. != null and . != ""))
        | join(" · ")
    '
}

notify_long_markdown() {
    local event_json="$1"
    printf '%s' "$event_json" | jq -r '
        def present: . != null and . != "";
        def note: [.model, .cwd, .hostname] | map(select(. != null and . != "")) | join(" · ");
        def session_value:
            if .event_kind == "user_input" and (.session_id | present)
            then .session_id
            else .session_short
            end;
        (
            [
                (.summary_short // ""),
                "",
                "**项目**: " + (.project // "unknown"),
                "**事件**: " + (.event_name // "unknown")
            ]
            + (if (.tool_name | present) then ["**工具**: " + .tool_name] else [] end)
            + (if (.event_kind == "user_input" and (.question_count // 0) > 0)
               then ["**问题数**: " + ((.question_count // 0) | tostring)]
               else [] end)
            + (if (.event_kind == "user_input" and ((.option_labels // []) | length) > 0)
               then ["**选项**: " + ((.option_labels // []) | join(" / "))]
               else [] end)
            + (if (session_value | present) then ["**Session**: " + session_value] else [] end)
            + (if (note != "") then ["", note] else [] end)
        )
        | join("\n")
    '
}

notify_color_decimal() {
    local status_color="$1"
    case "$status_color" in
        green) echo "5763719" ;;
        orange) echo "16753920" ;;
        red) echo "15548997" ;;
        blue) echo "3447003" ;;
        *) echo "9807270" ;;
    esac
}
