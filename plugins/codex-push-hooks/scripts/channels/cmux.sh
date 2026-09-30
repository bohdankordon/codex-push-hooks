#!/usr/bin/env bash
# cmux native notification (OSC 777 protocol)
# Works both locally and over cmux ssh — remote notifications pass through to the local cmux sidebar

send_cmux() {
    local title="$1" body="$2" config="$3"

    # Prefer the cmux CLI (local)
    if command -v cmux &>/dev/null; then
        cmux notify --title "$title" --body "$body" 2>/dev/null && return 0
    fi

    # Fall back to OSC 777 (remote SSH passthrough / no CLI available)
    printf '\e]777;notify;%s;%s\a' "$title" "$body"
}
