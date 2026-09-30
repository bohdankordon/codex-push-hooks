#!/usr/bin/env bash
# macOS native system notification (osascript)

send_macos() {
    local title="$1" body="$2" config="$3"
    local sound
    sound=$(echo "$config" | jq -r '.sound // "Glass"')

    # Escape special characters to prevent osascript injection
    local safe_body safe_title
    safe_body=$(printf '%s' "$body" | sed 's/\\/\\\\/g;s/"/\\"/g')
    safe_title=$(printf '%s' "$title" | sed 's/\\/\\\\/g;s/"/\\"/g')

    osascript -e "display notification \"$safe_body\" with title \"$safe_title\" sound name \"$sound\"" 2>/dev/null || true
}
