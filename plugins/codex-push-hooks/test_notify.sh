#!/usr/bin/env bash
#
# Test script - verify push connectivity for each channel
#
# Usage:
#   bash test_notify.sh              # test every enabled channel
#   bash test_notify.sh bark         # test a single channel
#   bash test_notify.sh hook         # simulate the full hook flow (Claude Code field format)
#   bash test_notify.sh codex        # simulate a Codex CLI PermissionRequest event (prompt field)
#   bash test_notify.sh list         # list the enabled channels
#   bash test_notify.sh codex-plugin-hooks  # verify Codex plugin hooks do not depend on the session cwd
#   bash test_notify.sh user-input    # verify the request_user_input / request_user_input_async dispatcher and templates
#   bash test_notify.sh state         # verify session-scoped state, deduplication, and clearing
#   bash test_notify.sh render        # verify the notification title and body templates
#   bash test_notify.sh agents        # verify Reasonix / dsh agent detection and event fields
#   bash test_notify.sh config-paths  # verify canonical config discovery, legacy fallback, and precedence
#   bash test_notify.sh install-smoke  # verify installer canonical paths and legacy migration (no real credentials)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHANNELS_DIR="${SCRIPT_DIR}/scripts/channels"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Find the configuration file (same order as scripts/notify.sh)
CONFIG_FILE=""
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
REASONIX_HOME_DIR="${REASONIX_HOME:-${HOME}/.reasonix}"
DSH_HOME_DIR="${DSH_HOME:-${HOME}/.dsh}"
if [ -n "${CC_NOTIFY_CONFIG:-}" ] && [ -f "${CC_NOTIFY_CONFIG}" ]; then
    CONFIG_FILE="${CC_NOTIFY_CONFIG}"
elif [ -n "${PLUGIN_DATA:-}" ] && [ -f "${PLUGIN_DATA}/notify.json" ]; then
    CONFIG_FILE="${PLUGIN_DATA}/notify.json"
elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -f "${CLAUDE_PLUGIN_DATA}/notify.json" ]; then
    CONFIG_FILE="${CLAUDE_PLUGIN_DATA}/notify.json"
elif [ -f "${CODEX_HOME_DIR}/codex-push-hooks/notify.json" ]; then
    CONFIG_FILE="${CODEX_HOME_DIR}/codex-push-hooks/notify.json"
elif [ -f "${REASONIX_HOME_DIR}/codex-push-hooks/notify.json" ]; then
    CONFIG_FILE="${REASONIX_HOME_DIR}/codex-push-hooks/notify.json"
elif [ -f "${DSH_HOME_DIR}/codex-push-hooks/notify.json" ]; then
    CONFIG_FILE="${DSH_HOME_DIR}/codex-push-hooks/notify.json"
elif [ -f "${CODEX_HOME_DIR}/cc-notify-hooks/notify.json" ]; then
    # Legacy fallback: every canonical path above takes precedence over
    # every legacy path here, so a legacy file can never shadow a canonical
    # configuration from another agent.
    CONFIG_FILE="${CODEX_HOME_DIR}/cc-notify-hooks/notify.json"
elif [ -f "${REASONIX_HOME_DIR}/cc-notify-hooks/notify.json" ]; then
    # Legacy fallback: see above.
    CONFIG_FILE="${REASONIX_HOME_DIR}/cc-notify-hooks/notify.json"
elif [ -f "${DSH_HOME_DIR}/cc-notify-hooks/notify.json" ]; then
    # Legacy fallback: see above.
    CONFIG_FILE="${DSH_HOME_DIR}/cc-notify-hooks/notify.json"
elif [ -f "${HOME}/.claude/hooks/notify.json" ]; then
    CONFIG_FILE="${HOME}/.claude/hooks/notify.json"
fi

echo "========================================="
echo "  codex-push-hooks - connectivity tests"
echo "========================================="
echo ""

COMMAND="${1:-all}"

if [ -z "$CONFIG_FILE" ] &&
   [ "$COMMAND" != "codex-plugin-hooks" ] &&
   [ "$COMMAND" != "user-input" ] &&
   [ "$COMMAND" != "state" ] &&
   [ "$COMMAND" != "render" ] &&
   [ "$COMMAND" != "config-paths" ] &&
   [ "$COMMAND" != "install-smoke" ]; then
    echo -e "${RED}No configuration file found${NC}"
    echo "  Run bash install.sh first, or copy config/notify.example.json to"
    echo "  ~/.claude/hooks/notify.json"
    exit 1
fi

if [ -n "$CONFIG_FILE" ]; then
    echo -e "  Config file: ${CYAN}${CONFIG_FILE}${NC}"
    echo ""
fi

# Test a single channel
test_channel() {
    local name="$1"
    local ch_file="${CHANNELS_DIR}/${name}.sh"

    if [ ! -f "$ch_file" ]; then
        echo -e "${RED}[${name}]${NC} ❌ channel script not found: ${ch_file}"
        return 1
    fi

    local enabled
    enabled=$(jq -r ".channels.\"${name}\".enabled // false" "$CONFIG_FILE")
    if [ "$enabled" != "true" ]; then
        echo -e "${YELLOW}[${name}]${NC} ⏭ not enabled, skipping"
        return 0
    fi

    local config
    config=$(jq -c ".channels.\"${name}\"" "$CONFIG_FILE")

    echo -e "${YELLOW}[${name}]${NC} sending a test notification..."

    # macOS is handled specially
    if [ "$name" = "macos" ]; then
        if [[ "$(uname -s)" != "Darwin" ]]; then
            echo -e "${YELLOW}[${name}]${NC} ⏭ not macOS, skipping"
            return 0
        fi
        source "$ch_file"
        send_macos "codex-push-hooks test" "Push notification connectivity test" "$config"
        echo -e "${GREEN}[${name}]${NC} ✅ sent, check your system notifications"
        return 0
    fi

    # Generic channel: rely on the curl return value
    source "$ch_file"

    # Temporarily override curl to capture the HTTP status code
    local result
    result=$(
        # Replace curl inside the send function so it emits the status code
        _original_curl=$(which curl)
        send_${name} "codex-push-hooks Test" "Push notification connectivity test" "$config" 2>&1
        echo "SEND_DONE"
    )

    # Simple check: a completed function counts as success (curl errors are swallowed by || true)
    echo -e "${GREEN}[${name}]${NC} ✅ sent, check whether the target platform received it"

    # Show channel details
    case "$name" in
        bark)
            local key
            key=$(echo "$config" | jq -r '.key // empty')
            echo -e "  Key: ${key:0:8}..."
            ;;
        telegram)
            local chat_id
            chat_id=$(echo "$config" | jq -r '.chat_id // empty')
            echo -e "  Chat ID: $chat_id"
            ;;
        wechat|feishu|dingtalk|slack|discord)
            local webhook
            webhook=$(echo "$config" | jq -r '.webhook // empty')
            echo -e "  Webhook: ${webhook:0:50}..."
            ;;
        ntfy)
            local topic server
            topic=$(echo "$config" | jq -r '.topic // empty')
            server=$(echo "$config" | jq -r '.server // "https://ntfy.sh"')
            echo -e "  Topic: $topic @ $server"
            ;;
        pushover)
            local user_key
            user_key=$(echo "$config" | jq -r '.user_key // empty')
            echo -e "  User: ${user_key:0:8}..."
            ;;
        gotify)
            local server
            server=$(echo "$config" | jq -r '.server // empty')
            echo -e "  Server: $server"
            ;;
    esac
}

# List the status of every channel
list_channels() {
    echo "  Channel status:"
    echo ""
    printf "  %-15s %-10s %-10s %s\n" "CHANNEL" "STATUS" "DELAY" "EVENTS"
    printf "  %-15s %-10s %-10s %s\n" "-------" "------" "-----" "------"

    for ch_file in "${CHANNELS_DIR}"/*.sh; do
        local name
        name=$(basename "$ch_file" .sh)
        local enabled delay events
        enabled=$(jq -r ".channels.\"${name}\".enabled // false" "$CONFIG_FILE")
        delay=$(jq -r ".channels.\"${name}\".delay // \"-\"" "$CONFIG_FILE")
        events=$(jq -r ".channels.\"${name}\".events // [\"notification\",\"stop\"] | join(\",\")" "$CONFIG_FILE")

        if [ "$enabled" = "true" ]; then
            printf "  %-15s ${GREEN}%-10s${NC} %-10s %s\n" "$name" "enabled" "${delay}s" "$events"
        else
            printf "  %-15s %-10s %-10s %s\n" "$name" "disabled" "${delay}s" "$events"
        fi
    done
}

# Simulate the hook flow
test_hook_flow() {
    echo -e "${YELLOW}[Mock Hook]${NC} simulating the full tiered push flow..."
    echo ""

    # Show the channels that will fire
    list_channels
    echo ""

    MOCK_JSON='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your response","cwd":"'"$PWD"'","session_id":"test-session"}'

    echo "$MOCK_JSON" | bash "${SCRIPT_DIR}/scripts/notify.sh" notification

    echo -e "${GREEN}[Mock Hook]${NC} ✅ background push process started"
    echo ""
    echo "  Enabled channels will push in delay order"
    echo "  Simulate a cancellation: bash ${SCRIPT_DIR}/scripts/clear_pending.sh < /dev/null"
}

# Simulate the Codex CLI hook flow
test_codex_flow() {
    echo -e "${YELLOW}[Mock Codex Hook]${NC} simulating a Codex PermissionRequest event..."
    echo "  Field difference: Codex uses the prompt field instead of message, and the event name is PermissionRequest"
    echo ""

    list_channels
    echo ""

    # Codex stdin format: the prompt field instead of message, with hook_event_name = PermissionRequest
    MOCK_JSON='{"hook_event_name":"PermissionRequest","prompt":"Codex requests to run a Bash command","cwd":"'"$PWD"'","session_id":"codex-test-session","model":"gpt-5.5"}'

    echo "$MOCK_JSON" | bash "${SCRIPT_DIR}/scripts/notify.sh" notification

    echo -e "${GREEN}[Mock Codex Hook]${NC} ✅ background push process started"
    echo ""
    echo "  Enabled channels will push in delay order"
    echo "  Simulate a cancellation (Codex UserPromptSubmit):"
    echo "    echo '{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}' | bash ${SCRIPT_DIR}/scripts/clear_pending.sh"
}

# Verify that the packaged Codex plugin hooks can use the runtime path variables from any session cwd
test_codex_plugin_hooks() {
    (
        set -euo pipefail
        echo -e "${YELLOW}[Codex Plugin Hooks]${NC} verifying PLUGIN_ROOT, PLUGIN_DATA, and a custom CODEX_HOME..."

        local tmp_base tmp_root tmp_home plugin_data custom_codex_home
        local stop_cmd clear_cmd pre_cmd post_cmd out
        tmp_base="${TMPDIR:-/tmp}"
        tmp_root=$(mktemp -d "${tmp_base%/}/codex-push-hooks.XXXXXX")
        trap 'rm -rf "$tmp_root"' EXIT
        tmp_home="${tmp_root}/home"
        plugin_data="${tmp_root}/plugin-data"
        custom_codex_home="${tmp_root}/custom-codex"
        mkdir -p "$tmp_home" "$plugin_data/state" "${custom_codex_home}/codex-push-hooks"
        printf '%s\n' '{"channels":{},"rate_limit":10}' > "${plugin_data}/notify.json"
        printf '%s\n' '{"channels":{},"rate_limit":10}' > "${custom_codex_home}/codex-push-hooks/notify.json"

        stop_cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "${SCRIPT_DIR}/hooks/codex-hooks.json")
        clear_cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "${SCRIPT_DIR}/hooks/codex-hooks.json")
        pre_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${SCRIPT_DIR}/hooks/codex-hooks.json")
        post_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "${SCRIPT_DIR}/hooks/codex-hooks.json")

        cd "$tmp_base"
        printf '%s' '{"hook_event_name":"Stop","session_id":"codex-plugin-test","cwd":"'"$tmp_base"'"}' \
            | HOME="$tmp_home" CODEX_HOME="$custom_codex_home" PLUGIN_ROOT="$SCRIPT_DIR" PLUGIN_DATA="$plugin_data" \
                bash -c "$stop_cmd"

        out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"codex-plugin-test","turn_id":"turn-plugin","tool_name":"request_user_input","tool_use_id":"call-plugin","tool_input":{"questions":[{"header":"Confirm","question":"Continue?","options":[{"label":"Continue"},{"label":"Cancel"}]}]},"cwd":"'"$tmp_base"'"}' \
            | HOME="$tmp_home" CODEX_HOME="$custom_codex_home" PLUGIN_ROOT="$SCRIPT_DIR" PLUGIN_DATA="$plugin_data" \
                CC_NOTIFY_RENDER_ONLY=1 bash -c "$pre_cmd")

        if [ "$(printf '%s' "$out" | jq -r '.event_kind')" != "user_input" ]; then
            echo -e "${RED}[Codex Plugin Hooks]${NC} PreToolUse did not run the dispatcher through PLUGIN_ROOT"
            return 1
        fi

        touch "${plugin_data}/state/pending_codex-plugin-test_user_input_call-plugin_1_1"
        printf '%s' '{"hook_event_name":"PostToolUse","session_id":"codex-plugin-test","tool_name":"request_user_input","tool_use_id":"call-plugin"}' \
            | HOME="$tmp_home" CODEX_HOME="$custom_codex_home" PLUGIN_ROOT="$SCRIPT_DIR" PLUGIN_DATA="$plugin_data" \
                bash -c "$post_cmd"
        if compgen -G "${plugin_data}/state/pending_codex-plugin-test_user_input_*" >/dev/null; then
            echo -e "${RED}[Codex Plugin Hooks]${NC} PostToolUse did not clear the user_input pending marker"
            return 1
        fi

        printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"codex-plugin-test","prompt":"hello"}' \
            | HOME="$tmp_home" CODEX_HOME="$custom_codex_home" PLUGIN_ROOT="$SCRIPT_DIR" PLUGIN_DATA="$plugin_data" \
                bash -c "$clear_cmd"

        if [ ! -f "${plugin_data}/state/last_codex-plugin-test_stop" ]; then
            echo -e "${RED}[Codex Plugin Hooks]${NC} the Stop hook did not write to the PLUGIN_DATA state directory"
            return 1
        fi

        printf '%s' '{"hook_event_name":"Stop","session_id":"standalone-test","cwd":"'"$tmp_base"'"}' \
            | HOME="$tmp_home" CODEX_HOME="$custom_codex_home" CC_NOTIFY_STATE_DIR="${tmp_root}/standalone-state" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        if [ ! -f "${tmp_root}/standalone-state/last_standalone-test_stop" ]; then
            echo -e "${RED}[Codex Plugin Hooks]${NC} notify.sh did not read the configuration from the custom CODEX_HOME"
            return 1
        fi

        echo -e "${GREEN}[Codex Plugin Hooks]${NC} ✅ runtime paths and the custom CODEX_HOME behave as expected"
    )
}

test_user_input_flow() {
    (
        set -euo pipefail
        echo -e "${YELLOW}[request_user_input]${NC} verifying the dispatcher, templates, and quiet degradation..."

        local tmp_base tmp_root state_dir out markdown fallback_out empty_out invalid_out no_jq_out
        local async_out async_empty_out async_free_out async_null_out async_config pre_matcher post_matcher
        local capture_file feishu_payload discord_payload
        local bash_bin minimal_bin
        tmp_base="${TMPDIR:-/tmp}"
        tmp_root=$(mktemp -d "${tmp_base%/}/codex-push-hooks-user-input.XXXXXX")
        trap 'rm -rf "$tmp_root"' EXIT
        state_dir="${tmp_root}/state"
        mkdir -p "$state_dir"

        out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"session-user-input","turn_id":"turn-user-input","tool_name":"request_user_input","tool_use_id":"call-user-input","tool_input":{"questions":[{"header":"Scope","question":"What does this fix cover?","options":[{"label":"Full fix"},{"label":"Minimal patch"}]},{"header":"Notification","question":"Which channel should be used?","options":[{"label":"macOS"},{"label":"Bark"}]}]},"cwd":"/tmp/demo-project","model":"gpt-5.5"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")

        if [ "$(printf '%s' "$out" | jq -r '.title')" != "Codex · Reply needed 🔔" ] ||
           [ "$(printf '%s' "$out" | jq -r '.summary_short')" != "Scope" ] ||
           [ "$(printf '%s' "$out" | jq -r '.event_kind')" != "user_input" ] ||
           [ "$(printf '%s' "$out" | jq -r '.question_count')" != "2" ] ||
           [ "$(printf '%s' "$out" | jq -r '.option_labels | join(",")')" != "Full fix,Minimal patch" ] ||
           [[ "$(printf '%s' "$out" | jq -r '.body')" != *"Questions: 2 · Session session-"* ]]; then
            echo -e "${RED}[request_user_input]${NC} structured notification fields are wrong: $out"
            return 1
        fi

        source "${SCRIPT_DIR}/scripts/lib/notify_format.sh"
        markdown=$(notify_long_markdown "$out")
        if [[ "$markdown" != *"**Questions**: 2"* ]] ||
           [[ "$markdown" != *"**Options**: Full fix / Minimal patch"* ]] ||
           [[ "$markdown" != *"**Session**: session-user-input"* ]] ||
           [[ "$markdown" != *"/tmp/demo-project"* ]]; then
            echo -e "${RED}[request_user_input]${NC} fallback notification fields are wrong: $markdown"
            return 1
        fi

        capture_file="${tmp_root}/channel-payload.json"
        curl() {
            local previous="" argument
            for argument in "$@"; do
                if [ "$previous" = "-d" ]; then
                    printf '%s' "$argument" > "$capture_file"
                    return 0
                fi
                previous="$argument"
            done
            return 0
        }

        source "${SCRIPT_DIR}/scripts/channels/feishu.sh"
        send_feishu "$(printf '%s' "$out" | jq -r '.title')" "$(printf '%s' "$out" | jq -r '.body')" '{"webhook":"https://example.invalid","format":"card"}' "$out"
        feishu_payload=$(cat "$capture_file")
        if ! printf '%s' "$feishu_payload" | jq -e '
            .card.elements[1].fields as $fields
            | any($fields[]; .text.content == "**Questions**\n2")
              and any($fields[]; .text.content == "**Options**\nFull fix / Minimal patch")
              and any($fields[]; .text.content == "**Session**\nsession-user-input")
        ' >/dev/null; then
            echo -e "${RED}[request_user_input]${NC} the Feishu card is missing structured question fields: $feishu_payload"
            return 1
        fi

        source "${SCRIPT_DIR}/scripts/channels/discord.sh"
        send_discord "$(printf '%s' "$out" | jq -r '.title')" "$(printf '%s' "$out" | jq -r '.body')" '{"webhook":"https://example.invalid","format":"embed"}' "$out"
        discord_payload=$(cat "$capture_file")
        if ! printf '%s' "$discord_payload" | jq -e '
            .embeds[0].fields as $fields
            | any($fields[]; .name == "Questions" and .value == "2")
              and any($fields[]; .name == "Options" and .value == "Full fix / Minimal patch")
              and any($fields[]; .name == "Session" and .value == "session-user-input")
        ' >/dev/null; then
            echo -e "${RED}[request_user_input]${NC} the Discord embed is missing structured question fields: $discord_payload"
            return 1
        fi

        fallback_out=$(printf '%s' '{"hook_event_name":"PreToolUse","turn_id":"turn-only-123","tool_name":"request_user_input","tool_use_id":"call-fallback","tool_input":{"questions":[{"header":"","question":"Choose the fix scope","options":[{"label":"Full"},{"label":"Minimal"}]}]},"cwd":"/tmp/demo-project"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        if [ "$(printf '%s' "$fallback_out" | jq -r '.summary_short')" != "Choose the fix scope" ] ||
           [ "$(printf '%s' "$fallback_out" | jq -r '.session_short')" != "turn-onl" ]; then
            echo -e "${RED}[request_user_input]${NC} question/turn_id fallback is wrong: $fallback_out"
            return 1
        fi

        async_out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"session-async-input","turn_id":"turn-async","tool_name":"request_user_input_async","tool_use_id":"call-async-input","tool_input":{"questions":[{"title":"Which environment should I use?","options":["Staging","Production"]}]},"cwd":"/tmp/demo-project","model":"gpt-5.5"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        if [ "$(printf '%s' "$async_out" | jq -r '.title')" != "Codex · Reply needed 🔔" ] ||
           [ "$(printf '%s' "$async_out" | jq -r '.event_kind')" != "user_input" ] ||
           [ "$(printf '%s' "$async_out" | jq -r '.question_count')" != "1" ] ||
           [ "$(printf '%s' "$async_out" | jq -r '.summary_short')" != "Which environment should I use?" ] ||
           [ "$(printf '%s' "$async_out" | jq -r '.option_labels | join(",")')" != "Staging,Production" ]; then
            echo -e "${RED}[request_user_input_async]${NC} the async question fixture is rendered wrong: $async_out"
            return 1
        fi

        touch "${state_dir}/pending_async-empty_user_input_call-async-empty_1_1"
        async_empty_out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"async-empty","tool_name":"request_user_input_async","tool_use_id":"call-async-empty","tool_input":{"questions":[]}}' \
            | CC_NOTIFY_STATE_DIR="$state_dir" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        if [ -n "$async_empty_out" ] ||
           ! compgen -G "${state_dir}/pending_async-empty_*" >/dev/null; then
            echo -e "${RED}[request_user_input_async]${NC} an empty async question list must stay quiet and keep pending state"
            return 1
        fi

        async_free_out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"async-free","turn_id":"turn-async-free","tool_name":"request_user_input_async","tool_use_id":"call-async-free","tool_input":{"questions":[{"title":"Describe the environment"}]},"cwd":"/tmp/demo-project"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        if [ "$(printf '%s' "$async_free_out" | jq -r '.event_kind')" != "user_input" ] ||
           [ "$(printf '%s' "$async_free_out" | jq -r '.question_count')" != "1" ] ||
           [ "$(printf '%s' "$async_free_out" | jq -r '.option_labels | length')" != "0" ] ||
           [ "$(printf '%s' "$async_free_out" | jq -r '.summary_short')" != "Describe the environment" ]; then
            echo -e "${RED}[request_user_input_async]${NC} the free-text async question is rendered wrong: $async_free_out"
            return 1
        fi

        # The runtime models options as Option<Vec<String>>, so an explicit null
        # is valid and behaves like options omitted.
        async_null_out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"async-null","turn_id":"turn-async-null","tool_name":"request_user_input_async","tool_use_id":"call-async-null","tool_input":{"questions":[{"title":"Describe the environment","options":null}]},"cwd":"/tmp/demo-project"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        if [ "$(printf '%s' "$async_null_out" | jq -r '.event_kind')" != "user_input" ] ||
           [ "$(printf '%s' "$async_null_out" | jq -r '.option_labels | length')" != "0" ]; then
            echo -e "${RED}[request_user_input_async]${NC} explicit null options must be valid and render with zero option labels: $async_null_out"
            return 1
        fi

        # Payloads the current async handler rejects (validated after PreToolUse)
        # must stay quiet AND keep existing pending state: no notify, no clear.
        async_invalid_case() {
            local name="$1" fixture="$2"
            local invalid_state="${tmp_root}/state-async-${name}"
            local invalid_out count
            mkdir -p "$invalid_state"
            touch "${invalid_state}/pending_${name}_user_input_x_1_1"
            invalid_out=$(printf '%s' "$fixture" \
                | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_STATE_DIR="$invalid_state" \
                    bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
            count=$(compgen -G "${invalid_state}/pending_*" | wc -l || true)
            if [ -n "$invalid_out" ] ||
               [ ! -f "${invalid_state}/pending_${name}_user_input_x_1_1" ] ||
               [ "$count" != "1" ]; then
                echo -e "${RED}[request_user_input_async]${NC} the invalid async payload ($name) must stay quiet, keep pending state, and create nothing"
                return 1
            fi
        }

        async_config="${tmp_root}/async-notify.json"
        printf '%s\n' '{"channels":{},"rate_limit":10}' > "$async_config"
        async_invalid_case 'objopts' '{"hook_event_name":"PreToolUse","session_id":"objopts","tool_name":"request_user_input_async","tool_use_id":"call-async-1","tool_input":{"questions":[{"title":"Which environment?","options":[{"label":"Staging"},{"label":"Production"}]}]}}'
        async_invalid_case 'emptyopts' '{"hook_event_name":"PreToolUse","session_id":"emptyopts","tool_name":"request_user_input_async","tool_use_id":"call-async-2","tool_input":{"questions":[{"title":"Which environment?","options":[]}]}}'
        async_invalid_case 'blanktitle' '{"hook_event_name":"PreToolUse","session_id":"blanktitle","tool_name":"request_user_input_async","tool_use_id":"call-async-3","tool_input":{"questions":[{"title":"   ","options":["A"]}]}}'
        async_invalid_case 'nonstring' '{"hook_event_name":"PreToolUse","session_id":"nonstring","tool_name":"request_user_input_async","tool_use_id":"call-async-4","tool_input":{"questions":[{"title":"Which environment?","options":["A",123]}]}}'
        async_invalid_case 'unknownfield' '{"hook_event_name":"PreToolUse","session_id":"unknownfield","tool_name":"request_user_input_async","tool_use_id":"call-async-5","tool_input":{"questions":[{"title":"Question?","extra":true}]}}'
        async_invalid_case 'laterinvalid' '{"hook_event_name":"PreToolUse","session_id":"laterinvalid","tool_name":"request_user_input_async","tool_use_id":"call-async-6","tool_input":{"questions":[{"title":"First?","options":["A"]},{"title":"  "}]}}'
        async_invalid_case 'rootextra' '{"hook_event_name":"PreToolUse","session_id":"rootextra","tool_name":"request_user_input_async","tool_use_id":"call-async-7","tool_input":{"questions":[{"title":"Question?"}],"extra":true}}'
        async_invalid_case 'toolinputarr' '{"hook_event_name":"PreToolUse","session_id":"toolinputarr","tool_name":"request_user_input_async","tool_use_id":"call-async-8","tool_input":["questions"]}'

        if compgen -G "${state_dir}/awaiting_async_"* >/dev/null; then
            echo -e "${RED}[request_user_input_async]${NC} an invalid async payload must not create async waiting state"
            return 1
        fi

        # Async lifecycle: the async tool's immediate completion is NOT wired to the
        # PostToolUse user_input clear hook -- the later UserPromptSubmit clears instead.
        pre_matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "${SCRIPT_DIR}/hooks/codex-hooks.json")
        post_matcher=$(jq -r '.hooks.PostToolUse[0].matcher' "${SCRIPT_DIR}/hooks/codex-hooks.json")
        if [ "$pre_matcher" != "*" ] ||
           [ "$post_matcher" != '^request_user_input$' ] ||
           printf '%s' 'request_user_input_async' | grep -Eq "$post_matcher"; then
            echo -e "${RED}[request_user_input_async]${NC} the PostToolUse clear matcher must stay exactly ^request_user_input\$ so async completion keeps the pending marker"
            return 1
        fi

        touch \
            "${state_dir}/pending_session-a_notification_call-a_1_1" \
            "${state_dir}/pending_session-b_notification_call-b_1_1"
        printf '%s' '{"hook_event_name":"PreToolUse","session_id":"session-a","tool_name":"Bash","tool_input":{"command":"true"}}' \
            | CC_NOTIFY_STATE_DIR="$state_dir" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        if compgen -G "${state_dir}/pending_session-a_*" >/dev/null ||
           ! compgen -G "${state_dir}/pending_session-b_*" >/dev/null; then
            echo -e "${RED}[request_user_input]${NC} a plain PreToolUse did not clear per session"
            return 1
        fi

        empty_out=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"empty","tool_name":"request_user_input","tool_input":{"questions":[]}}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")
        invalid_out=$(printf '%s' '{invalid json' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh")

        bash_bin=$(command -v bash)
        minimal_bin="${tmp_root}/minimal-bin"
        mkdir -p "$minimal_bin"
        ln -s "$(command -v cat)" "${minimal_bin}/cat"
        ln -s "$(command -v dirname)" "${minimal_bin}/dirname"
        no_jq_out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[{"question":"test"}]}}' \
            | PATH="$minimal_bin" "$bash_bin" "${SCRIPT_DIR}/scripts/pre_tool_use.sh")

        if [ -n "$empty_out" ] || [ -n "$invalid_out" ] || [ -n "$no_jq_out" ]; then
            echo -e "${RED}[request_user_input]${NC} empty questions, invalid JSON, or a missing jq must produce no output"
            return 1
        fi

        echo -e "${GREEN}[request_user_input]${NC} ✅ dispatcher and notification templates behave as expected"
    )
}

test_session_state() {
    (
        set -euo pipefail
        shopt -s nullglob
        echo -e "${YELLOW}[Session State]${NC} verifying pending, rate limit, deduplication, and /exit isolation..."

        local tmp_base tmp_root state_dir config_file event_a event_a_new event_b
        local first_pending repeated_pending new_pending
        tmp_base="${TMPDIR:-/tmp}"
        tmp_root=$(mktemp -d "${tmp_base%/}/codex-push-hooks-state.XXXXXX")
        trap 'rm -rf "$tmp_root"' EXIT
        state_dir="${tmp_root}/state"
        config_file="${tmp_root}/notify.json"
        mkdir -p "$state_dir"
        printf '%s\n' '{"channels":{},"rate_limit":10}' > "$config_file"

        event_a='{"hook_event_name":"PreToolUse","session_id":"session-a","turn_id":"turn-a","tool_name":"request_user_input","tool_use_id":"call-a","tool_input":{"questions":[{"header":"A","question":"Question A","options":[{"label":"Yes"},{"label":"No"}]}]},"cwd":"/tmp/project-a"}'
        event_a_new=$(printf '%s' "$event_a" | jq -c '.tool_use_id = "call-a-new"')
        event_b=$(printf '%s' "$event_a" | jq -c '.session_id = "session-b" | .turn_id = "turn-b" | .tool_use_id = "call-b" | .tool_input.questions[0].header = "B"')

        printf '%s' "$event_a" \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" notification user_input
        first_pending=$(compgen -G "${state_dir}/pending_session-a_user_input_*" | head -n 1)
        [ -n "$first_pending" ] || { echo -e "${RED}[Session State]${NC} session A did not create a pending marker"; return 1; }

        printf '%s' "$event_a" \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" notification user_input
        repeated_pending=$(compgen -G "${state_dir}/pending_session-a_user_input_*" | head -n 1)
        if [ "$repeated_pending" != "$first_pending" ]; then
            echo -e "${RED}[Session State]${NC} the same tool_use_id was not deduplicated"
            return 1
        fi

        printf '%s' "$event_a_new" \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" notification user_input
        new_pending=$(compgen -G "${state_dir}/pending_session-a_user_input_*" | head -n 1)
        if [ "$new_pending" = "$first_pending" ]; then
            echo -e "${RED}[Session State]${NC} a different tool_use_id was swallowed by the ten-second rate limit"
            return 1
        fi

        printf '%s' "$event_b" \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" notification user_input
        if ! compgen -G "${state_dir}/pending_session-a_user_input_*" >/dev/null ||
           ! compgen -G "${state_dir}/pending_session-b_user_input_*" >/dev/null ||
           [ ! -f "${state_dir}/last_session-a_user_input" ] ||
           [ ! -f "${state_dir}/last_session-b_user_input" ]; then
            echo -e "${RED}[Session State]${NC} pending/rate state is not isolated between the two sessions"
            return 1
        fi

        printf '%s' '{"hook_event_name":"PostToolUse","session_id":"session-a","tool_name":"request_user_input","tool_use_id":"call-a-new"}' \
            | CC_NOTIFY_STATE_DIR="$state_dir" bash "${SCRIPT_DIR}/scripts/clear_pending.sh" user_input
        if compgen -G "${state_dir}/pending_session-a_user_input_*" >/dev/null ||
           ! compgen -G "${state_dir}/pending_session-b_user_input_*" >/dev/null; then
            echo -e "${RED}[Session State]${NC} the PostToolUse clear affected another session"
            return 1
        fi

        printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"session-a","prompt":"/exit"}' \
            | CC_NOTIFY_STATE_DIR="$state_dir" bash "${SCRIPT_DIR}/scripts/clear_pending.sh"
        [ -f "${state_dir}/exiting_session-a" ] || { echo -e "${RED}[Session State]${NC} /exit was not recorded per session"; return 1; }

        printf '%s' '{"hook_event_name":"Stop","session_id":"session-b","cwd":"/tmp/project-b"}' \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        [ -f "${state_dir}/last_session-b_stop" ] || { echo -e "${RED}[Session State]${NC} session A's /exit wrongly suppressed session B"; return 1; }

        printf '%s' '{"hook_event_name":"Stop","session_id":"session-a","cwd":"/tmp/project-a"}' \
            | CC_NOTIFY_CONFIG="$config_file" CC_NOTIFY_STATE_DIR="$state_dir" \
                bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        if [ -f "${state_dir}/exiting_session-a" ] || [ -f "${state_dir}/last_session-a_stop" ]; then
            echo -e "${RED}[Session State]${NC} the /exit Stop suppression behavior is wrong"
            return 1
        fi

        # ---- async waiting state (real Stage 3B lifecycle) ----
        # A live async question keeps its Reply-needed delivery pending until the
        # user answers (UserPromptSubmit). Unrelated tool activity, the turn's Stop,
        # and a completed delivery must not end that waiting state.
        local async_state async_cap async_config async_event async_other async_second
        local async_tool async_stop async_ups sync_name
        async_state="${tmp_root}/async-state"
        async_cap="${tmp_root}/async-cap"
        async_config="${tmp_root}/async-notify.json"
        mkdir -p "$async_state" "$async_cap"
        printf '%s\n' '{"channels":{"telegram":{"enabled":true,"delay":3600,"bot_token":"F","chat_id":"0"}},"rate_limit":0}' > "$async_config"
        async_event='{"hook_event_name":"PreToolUse","session_id":"session-async","turn_id":"turn-async","tool_name":"request_user_input_async","tool_use_id":"call-async","tool_input":{"questions":[{"title":"Which environment should I use?","options":["Staging","Production"]}]},"cwd":"/tmp/project-async"}'
        async_other='{"hook_event_name":"PermissionRequest","session_id":"session-async","tool_name":"Bash","prompt":"allow?"}'
        async_second=$(printf '%s' "$async_event" | jq -c '.tool_use_id = "call-async-2" | .tool_input.questions[0].title = "Second question?"')
        async_tool='{"hook_event_name":"PreToolUse","session_id":"session-async","tool_name":"sleep","tool_input":{"duration_ms":600000}}'
        async_stop='{"hook_event_name":"Stop","session_id":"session-async"}'
        async_ups='{"hook_event_name":"UserPromptSubmit","session_id":"session-async","message":"Staging"}'

        # Neighbour session state must stay untouched by every step below.
        touch "${async_state}/pending_session-neighbour_user_input_other_1_1"
        touch "${async_state}/awaiting_async_session-neighbour_other"

        printf '%s' "$async_event" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        compgen -G "${async_state}/pending_session-async_user_input_call-async_*" >/dev/null || { echo -e "${RED}[Async waiting]${NC} the async question did not create a delivery pending"; return 1; }
        compgen -G "${async_state}/awaiting_async_session-async_call-async" >/dev/null || { echo -e "${RED}[Async waiting]${NC} the async question did not start waiting state"; return 1; }

        printf '%s' "$async_tool" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        compgen -G "${async_state}/pending_session-async_user_input_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} ordinary tool activity must not delete the async delivery pending"; return 1; }
        compgen -G "${async_state}/awaiting_async_session-async_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} ordinary tool activity must not end async waiting"; return 1; }

        # A recognized sync/compat question tool with no questions is a quiet no-op:
        # it must not end the async wait or clear the reply pending.
        for sync_name in request_user_input ask AskUserQuestion; do
            printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-async\",\"tool_name\":\"${sync_name}\",\"tool_input\":{\"questions\":[]}}" \
                | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        done
        printf '%s' '{"hook_event_name":"PreToolUse","session_id":"session-async","tool_name":"request_user_input","tool_input":{}}' \
            | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        compgen -G "${async_state}/awaiting_async_session-async_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} an empty sync question must not end async waiting"; return 1; }
        compgen -G "${async_state}/pending_session-async_user_input_call-async_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} an empty sync question must not clear the reply pending"; return 1; }
        [ "$(compgen -G "${async_state}/pending_session-async_user_input_"* | wc -l)" -eq 1 ] || { echo -e "${RED}[Async waiting]${NC} an empty sync question must not create a new pending"; return 1; }

        printf '%s' "$async_other" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/notify.sh" notification
        compgen -G "${async_state}/pending_session-async_user_input_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} another notification must not delete the async delivery pending"; return 1; }
        compgen -G "${async_state}/pending_session-async_notification_"* >/dev/null || { echo -e "${RED}[Async waiting]${NC} the other notification did not get its own pending"; return 1; }

        printf '%s' "$async_stop" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        if compgen -G "${async_state}/pending_session-async_stop_"* >/dev/null || [ -f "${async_state}/last_session-async_stop" ]; then
            echo -e "${RED}[Async waiting]${NC} Stop while waiting for an async reply must be skipped entirely"
            return 1
        fi

        # A completed delivery removes the pending marker, but the session is
        # still waiting for the answer.
        rm -f "${async_state}/pending_session-async_user_input_"* 2>/dev/null || true
        printf '%s' "$async_stop" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        if [ -f "${async_state}/last_session-async_stop" ] || ! compgen -G "${async_state}/awaiting_async_session-async_"* >/dev/null; then
            echo -e "${RED}[Async waiting]${NC} async waiting must outlive the delivery that the worker removed"
            return 1
        fi

        printf '%s' "$async_ups" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/clear_pending.sh"
        if compgen -G "${async_state}/awaiting_async_session-async_"* >/dev/null; then
            echo -e "${RED}[Async waiting]${NC} the user's answer must end async waiting"
            return 1
        fi

        printf '%s' "$async_stop" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/notify.sh" stop
        [ -f "${async_state}/last_session-async_stop" ] || { echo -e "${RED}[Async waiting]${NC} Stop must follow the normal path once the answer arrived"; return 1; }

        # A newer async question supersedes the previous waiting state and delivery.
        touch "${async_state}/pending_session-async_user_input_call-async_old"
        printf '%s' "$async_second" | CC_NOTIFY_CONFIG="$async_config" CC_NOTIFY_CAPTURE_DIR="$async_cap" CC_NOTIFY_STATE_DIR="$async_state" bash "${SCRIPT_DIR}/scripts/pre_tool_use.sh"
        [ "$(compgen -G "${async_state}/awaiting_async_session-async_"* | wc -l)" -eq 1 ] || { echo -e "${RED}[Async waiting]${NC} a second async question must leave exactly one canonical waiting marker"; return 1; }
        compgen -G "${async_state}/awaiting_async_session-async_call-async-2" >/dev/null || { echo -e "${RED}[Async waiting]${NC} the newer async question must become canonical"; return 1; }
        if compgen -G "${async_state}/pending_session-async_user_input_"* | grep -q 'call-async_old'; then
            echo -e "${RED}[Async waiting]${NC} the superseded delivery pending must not remain active"
            return 1
        fi

        if ! compgen -G "${async_state}/pending_session-neighbour_user_input_other_1_1" >/dev/null ||
           ! compgen -G "${async_state}/awaiting_async_session-neighbour_other" >/dev/null; then
            echo -e "${RED}[Async waiting]${NC} async state transitions must stay session-scoped"
            return 1
        fi

        echo -e "${GREEN}[Session State]${NC} ✅ session state, precise deduplication, and clearing behave as expected"
    )
}

test_render_templates() {
    echo -e "${YELLOW}[Template rendering]${NC} verifying short-delay and structured fallback notification fields..."

    local out title body summary event_name tool_name status_label
    out=$(
        printf '%s' '{"hook_event_name":"Stop","session_id":"render-codex","cwd":"/tmp/demo-project","model":"gpt-5.5","last_assistant_message":"Training status check finished\n\nFurther details stay out of the notification."}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" stop
    )
    title=$(echo "$out" | jq -r '.title')
    body=$(echo "$out" | jq -r '.body')
    summary=$(echo "$out" | jq -r '.summary_short')
    event_name=$(echo "$out" | jq -r '.event_name')
    tool_name=$(echo "$out" | jq -r '.tool_name')

    if [ "$title" != "Codex · Task complete ✅" ]; then
        echo -e "${RED}[Template rendering]${NC} Codex Stop title is wrong: $title"
        return 1
    fi
    if [[ "$body" != "[demo-project] Training status check finished"* ]]; then
        echo -e "${RED}[Template rendering]${NC} Codex Stop body is wrong: $body"
        return 1
    fi
    if [ "$summary" != "Training status check finished" ] || [ "$event_name" != "Stop" ] || [ -n "$tool_name" ]; then
        echo -e "${RED}[Template rendering]${NC} Codex Stop structured fields are wrong: $out"
        return 1
    fi
    # Guard against the deprecated v1 copy that hard-coded Claude into every body.
    if [[ "$body" == *"Claude has finished the work"* ]]; then
        echo -e "${RED}[Template rendering]${NC} Codex Stop still contains the legacy copy: $body"
        return 1
    fi
    if [[ "$body" == *"gpt-5.5"* ]] || [[ "$body" == *"on-request"* ]]; then
        echo -e "${RED}[Template rendering]${NC} the short-delay body must not contain the model or the permission mode: $body"
        return 1
    fi

    out=$(
        printf '%s' '{"hook_event_name":"Stop","session_id":"render-claude-stop","transcript_path":"/Users/test/.claude/projects/demo/session.jsonl","cwd":"/tmp/demo-project","model":"claude-sonnet-4-5","last_assistant_message":"The Claude side finished too."}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" stop
    )
    title=$(echo "$out" | jq -r '.title')
    body=$(echo "$out" | jq -r '.body')

    if [ "$title" != "Claude Code · Task complete ✅" ]; then
        echo -e "${RED}[Template rendering]${NC} Claude Stop title is wrong: $title"
        return 1
    fi
    if [[ "$body" != "[demo-project] The Claude side finished too."* ]]; then
        echo -e "${RED}[Template rendering]${NC} Claude Stop body is wrong: $body"
        return 1
    fi

    out=$(
        printf '%s' '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"render-claude","cwd":"/tmp/demo-project","model":"claude-sonnet-4-5","message":"Claude is waiting for your response"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" notification
    )
    title=$(echo "$out" | jq -r '.title')
    body=$(echo "$out" | jq -r '.body')
    status_label=$(echo "$out" | jq -r '.status_label')

    if [ "$title" != "Claude Code · Awaiting response ⏳" ]; then
        echo -e "${RED}[Template rendering]${NC} Claude Notification title is wrong: $title"
        return 1
    fi
    if [ "$status_label" != "Awaiting response ⏳" ]; then
        echo -e "${RED}[Template rendering]${NC} Claude Notification status is wrong: $status_label"
        return 1
    fi
    if [[ "$body" != "[demo-project] Claude is waiting for your response"* ]]; then
        echo -e "${RED}[Template rendering]${NC} Claude Notification body is wrong: $body"
        return 1
    fi

    out=$(
        printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"render-codex-perm","cwd":"/tmp/demo-project","model":"gpt-5.5","permission_mode":"on-request","tool_name":"Bash","prompt":"Requests to run a Bash command: git push origin main\n\nThe operation pushes the remote branch."}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" notification
    )
    title=$(echo "$out" | jq -r '.title')
    body=$(echo "$out" | jq -r '.body')
    summary=$(echo "$out" | jq -r '.summary_short')
    tool_name=$(echo "$out" | jq -r '.tool_name')

    if [ "$title" != "Codex · Approval needed 🔔" ]; then
        echo -e "${RED}[Template rendering]${NC} Codex Permission title is wrong: $title"
        return 1
    fi
    if [ "$summary" != "Requests to run a Bash command: git push origin main" ] || [ "$tool_name" != "Bash" ]; then
        echo -e "${RED}[Template rendering]${NC} Codex Permission summary or tool is wrong: $out"
        return 1
    fi
    if [[ "$body" != "[demo-project] Requests to run a Bash command: git push origin main · Bash" ]]; then
        echo -e "${RED}[Template rendering]${NC} Codex Permission short body is wrong: $body"
        return 1
    fi
    if [[ "$body" == *"on-request"* ]]; then
        echo -e "${RED}[Template rendering]${NC} the permission mode must not appear in the short body: $body"
        return 1
    fi

    local markdown
    source "${SCRIPT_DIR}/scripts/lib/notify_format.sh"
    markdown=$(notify_long_markdown "$out")
    if [[ "$markdown" != *"Requests to run a Bash command: git push origin main"* ]] ||
       [[ "$markdown" != *"**Project**: demo-project"* ]] ||
       [[ "$markdown" != *"**Event**: PermissionRequest"* ]] ||
       [[ "$markdown" != *"**Tool**: Bash"* ]] ||
       [[ "$markdown" != *"**Session**: render-c"* ]] ||
       [[ "$markdown" != *"gpt-5.5 · /tmp/demo-project"* ]]; then
        echo -e "${RED}[Template rendering]${NC} fallback notification Markdown is wrong: $markdown"
        return 1
    fi
    if [[ "$markdown" == *"on-request"* ]] || [[ "$markdown" == *"cc-notify-hooks ·"* ]]; then
        echo -e "${RED}[Template rendering]${NC} the fallback notification must not contain the permission mode or the legacy note: $markdown"
        return 1
    fi

    echo -e "${GREEN}[Template rendering]${NC} ✅ short-delay and fallback notification fields behave as expected"
}

# Verify agent detection and event-field compatibility for Reasonix / dsh
test_agent_detection() {
    echo -e "${YELLOW}[Agent detection]${NC} verifying Reasonix / dsh agent detection and event fields..."

    local out title body summary event_name

    # Reasonix plugin import format (Claude-shaped payload + REASONIX_PLUGIN_ROOT environment)
    out=$(
        printf '%s' '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"approval needed: bash git push origin main","session_id":"reasonix-session-1","cwd":"/tmp/demo-project"}' \
            | REASONIX_PLUGIN_ROOT="/fake/reasonix/plugins/codex-push-hooks" \
                CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" notification
    )
    title=$(echo "$out" | jq -r '.title')
    status_label=$(echo "$out" | jq -r '.status_label')
    summary=$(echo "$out" | jq -r '.summary_short')
    if [ "$title" != "Reasonix · Approval needed 🔔" ] || [ "$status_label" != "Approval needed 🔔" ] ||
       [ "$summary" != "approval needed: bash git push origin main" ]; then
        echo -e "${RED}[Agent detection]${NC} Reasonix Notification detection or template is wrong: $out"
        return 1
    fi

    # Reasonix native payload format (event / sessionId / lastAssistantText)
    out=$(
        printf '%s' '{"event":"Stop","sessionId":"reasonix-session-2","cwd":"/tmp/demo-project","lastAssistantText":"Checks finished","turn":1}' \
            | REASONIX_PLUGIN_ROOT="/fake/reasonix/plugins/codex-push-hooks" \
                CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" stop
    )
    title=$(echo "$out" | jq -r '.title')
    summary=$(echo "$out" | jq -r '.summary_short')
    if [ "$title" != "Reasonix · Task complete ✅" ] || [ "$summary" != "Checks finished" ]; then
        echo -e "${RED}[Agent detection]${NC} Reasonix native Stop fields are wrong: $out"
        return 1
    fi

    # dsh plugin environment (DSH_CC_NOTIFY) Stop event
    out=$(
        printf '%s' '{"hook_event_name":"Stop","session_id":"dsh-session-1","cwd":"/tmp/demo-project","stop_hook_active":false}' \
            | DSH_CC_NOTIFY=1 CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" stop
    )
    title=$(echo "$out" | jq -r '.title')
    body=$(echo "$out" | jq -r '.body')
    if [ "$title" != "dsh · Task complete ✅" ] || [[ "$body" != "[demo-project] Task completed"* ]]; then
        echo -e "${RED}[Agent detection]${NC} dsh Stop detection or template is wrong: $out"
        return 1
    fi

    # an explicit CC_NOTIFY_AGENT override wins over environment hints
    out=$(
        printf '%s' '{"hook_event_name":"Stop","session_id":"x","cwd":"/tmp/demo-project"}' \
            | REASONIX_PLUGIN_ROOT="/fake" DSH_CC_NOTIFY=1 CC_NOTIFY_AGENT="Custom Agent" \
                CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" stop
    )
    title=$(echo "$out" | jq -r '.title')
    if [ "$title" != "Custom Agent · Task complete ✅" ]; then
        echo -e "${RED}[Agent detection]${NC} the CC_NOTIFY_AGENT override did not take effect: $out"
        return 1
    fi

    # still detected by the original logic when no environment hints exist (Notification → Claude Code)
    out=$(
        printf '%s' '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting","session_id":"c","cwd":"/tmp/demo-project"}' \
            | CC_NOTIFY_RENDER_ONLY=1 bash "${SCRIPT_DIR}/scripts/notify.sh" notification
    )
    title=$(echo "$out" | jq -r '.title')
    if [ "$title" != "Claude Code · Awaiting response ⏳" ]; then
        echo -e "${RED}[Agent detection]${NC} Claude Notification was misidentified without environment hints: $out"
        return 1
    fi

    echo -e "${GREEN}[Agent detection]${NC} ✅ Reasonix / dsh / override order behave as expected"
}

# Verify canonical discovery, legacy fallback, and precedence for the
# Codex / Reasonix / dsh standalone configuration paths.
# No real credentials or notifications: curl is stubbed and every webhook
# points at example.invalid; only the selected marker URL is captured.
test_config_paths() {
    (
        set -euo pipefail
        echo -e "${YELLOW}[Config Paths]${NC} verifying canonical discovery, legacy fallback, and precedence..."

        local tmp_base tmp_root agent subdir case_dir fake_home override_file
        tmp_base="${TMPDIR:-/tmp}"
        tmp_root=$(mktemp -d "${tmp_base%/}/codex-push-hooks-config-paths.XXXXXX")
        trap 'rm -rf "$tmp_root"' EXIT

        # Stub network access: record the webhook URL instead of posting.
        curl() { printf '%s\n' "$@" > "${CURL_CAPTURE:-/dev/null}"; return 0; }
        export -f curl

        write_marker_config() {
            # $1 = config file, $2 = marker embedded in the webhook URL
            local cfg="$1" marker="$2"
            mkdir -p "$(dirname "$cfg")"
            printf '%s\n' '{"channels":{"feishu":{"enabled":true,"delay":0,"webhook":"https://example.invalid/'"$marker"'"}}}' > "$cfg"
        }

        run_lookup_case() {
            # $1 = case name, $2 = expected marker, remaining args = VAR=value environment
            local case_name="$1" expected="$2"
            shift 2
            local dir="${tmp_root}/${case_name}" capture="${tmp_root}/${case_name}/curl-args"
            mkdir -p "$dir"
            rm -f "$capture"
            printf '%s' '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"approval needed","session_id":"cfgpath-'"$case_name"'","cwd":"/tmp/demo-project"}' \
                | CC_NOTIFY_CONFIG= PLUGIN_DATA= CLAUDE_PLUGIN_DATA= \
                  CURL_CAPTURE="$capture" CC_NOTIFY_STATE_DIR="${dir}/state" \
                  env "$@" \
                  bash "${SCRIPT_DIR}/scripts/notify.sh" notification
            local waited=0
            while [ ! -f "$capture" ] && [ "$waited" -lt 30 ]; do
                sleep 0.5
                waited=$((waited + 1))
            done
            if [ ! -f "$capture" ]; then
                echo -e "${RED}[Config Paths]${NC} ${case_name}: no notification was sent (is jq installed?)"
                return 1
            fi
            if ! grep -q "$expected" "$capture"; then
                echo -e "${RED}[Config Paths]${NC} ${case_name}: expected marker ${expected}, got: $(cat "$capture")"
                return 1
            fi
            echo -e "  ${case_name}: ${expected} ✅"
        }

        for agent in codex reasonix dsh; do
            case "$agent" in
                codex) subdir=".codex" ;;
                reasonix) subdir=".reasonix" ;;
                dsh) subdir=".dsh" ;;
            esac

            # 1. canonical discovery
            case_dir="${tmp_root}/${agent}-canonical"
            fake_home="${case_dir}/home"
            write_marker_config "${fake_home}/${subdir}/codex-push-hooks/notify.json" "canonical-${agent}"
            run_lookup_case "${agent}-canonical" "canonical-${agent}" \
                HOME="$fake_home" \
                CODEX_HOME="${fake_home}/.codex" \
                REASONIX_HOME="${fake_home}/.reasonix" \
                DSH_HOME="${fake_home}/.dsh"

            # 2. legacy fallback
            case_dir="${tmp_root}/${agent}-legacy"
            fake_home="${case_dir}/home"
            write_marker_config "${fake_home}/${subdir}/cc-notify-hooks/notify.json" "legacy-${agent}"
            run_lookup_case "${agent}-legacy" "legacy-${agent}" \
                HOME="$fake_home" \
                CODEX_HOME="${fake_home}/.codex" \
                REASONIX_HOME="${fake_home}/.reasonix" \
                DSH_HOME="${fake_home}/.dsh"

            # 3. canonical wins when both exist
            case_dir="${tmp_root}/${agent}-both"
            fake_home="${case_dir}/home"
            write_marker_config "${fake_home}/${subdir}/codex-push-hooks/notify.json" "canonical-${agent}-both"
            write_marker_config "${fake_home}/${subdir}/cc-notify-hooks/notify.json" "legacy-${agent}-both"
            run_lookup_case "${agent}-both" "canonical-${agent}-both" \
                HOME="$fake_home" \
                CODEX_HOME="${fake_home}/.codex" \
                REASONIX_HOME="${fake_home}/.reasonix" \
                DSH_HOME="${fake_home}/.dsh"
        done

        # 4. a legacy path can never shadow a canonical path from another agent
        case_dir="${tmp_root}/cross-legacy-codex-canonical-reasonix"
        fake_home="${case_dir}/home"
        write_marker_config "${fake_home}/.codex/cc-notify-hooks/notify.json" "legacy-codex-shadow"
        write_marker_config "${fake_home}/.reasonix/codex-push-hooks/notify.json" "canonical-reasonix-wins"
        run_lookup_case "cross-legacy-codex-canonical-reasonix" "canonical-reasonix-wins" \
            HOME="$fake_home" \
            CODEX_HOME="${fake_home}/.codex" \
            REASONIX_HOME="${fake_home}/.reasonix" \
            DSH_HOME="${fake_home}/.dsh"

        case_dir="${tmp_root}/cross-legacy-codex-reasonix-canonical-dsh"
        fake_home="${case_dir}/home"
        write_marker_config "${fake_home}/.codex/cc-notify-hooks/notify.json" "legacy-codex-shadow"
        write_marker_config "${fake_home}/.reasonix/cc-notify-hooks/notify.json" "legacy-reasonix-shadow"
        write_marker_config "${fake_home}/.dsh/codex-push-hooks/notify.json" "canonical-dsh-wins"
        run_lookup_case "cross-legacy-codex-reasonix-canonical-dsh" "canonical-dsh-wins" \
            HOME="$fake_home" \
            CODEX_HOME="${fake_home}/.codex" \
            REASONIX_HOME="${fake_home}/.reasonix" \
            DSH_HOME="${fake_home}/.dsh"

        # 5. an explicit CC_NOTIFY_CONFIG override still wins over everything
        case_dir="${tmp_root}/explicit-override"
        fake_home="${case_dir}/home"
        override_file="${case_dir}/custom.json"
        write_marker_config "$override_file" "explicit-override"
        write_marker_config "${fake_home}/.codex/codex-push-hooks/notify.json" "canonical-codex-ignored"
        run_lookup_case "explicit-override" "explicit-override" \
            HOME="$fake_home" \
            CODEX_HOME="${fake_home}/.codex" \
            REASONIX_HOME="${fake_home}/.reasonix" \
            DSH_HOME="${fake_home}/.dsh" \
            CC_NOTIFY_CONFIG="$override_file"

        echo -e "${GREEN}[Config Paths]${NC} ✅ canonical discovery, legacy fallback, and precedence behave as expected"
    )
}

# Installer smoke tests: canonical paths are written fresh, a legacy
# configuration is reused (copied, never moved or deleted), and the dsh
# installer migrates the legacy insert entry instead of duplicating it.
# Everything runs under a sandboxed HOME; no real credentials are needed.
test_install_smoke() {
    (
        set -euo pipefail
        echo -e "${YELLOW}[Install Smoke]${NC} verifying canonical paths and legacy migration..."

        local tmp_base tmp_root repo_root probe_dir depth codex_home stubbin reasonix_home dsh_home
        local have_symlinks probe_src probe_link dsh_bad_home dsh_dup_home dsh_comment_home
        local dsh_file_home dsh_dir_home
        tmp_base="${TMPDIR:-/tmp}"
        tmp_root=$(mktemp -d "${tmp_base%/}/codex-push-hooks-install-smoke.XXXXXX")
        trap 'rm -rf "$tmp_root"' EXIT

        # Some Windows checkouts cannot create real symlinks (ln -s degrades to
        # a copy); link assertions below adapt, everything else is unaffected.
        probe_src="${tmp_root}/link-probe-src"
        probe_link="${tmp_root}/link-probe-link"
        mkdir -p "$probe_src"
        ln -s "$probe_src" "$probe_link" 2>/dev/null || true
        if [ -L "$probe_link" ]; then have_symlinks=1; else have_symlinks=0; fi
        rm -rf "$probe_src" "$probe_link"

        # Locate the repository root whether the test runs through the root
        # symlink or straight from the plugin directory.
        repo_root=""
        probe_dir="${SCRIPT_DIR}"
        for depth in 1 2 3 4; do
            if [ -f "${probe_dir}/install/codex.sh" ]; then
                repo_root="$(cd "$probe_dir" && pwd)"
                break
            fi
            probe_dir="${probe_dir}/.."
        done
        [ -n "$repo_root" ] \
            || { echo -e "${RED}[Install Smoke]${NC} repository root not found"; return 1; }

        # ---- Codex: legacy config is offered and reused into the canonical path ----
        codex_home="${tmp_root}/codex-home"
        mkdir -p "${codex_home}/.codex/cc-notify-hooks"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-bark-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${codex_home}/.codex/cc-notify-hooks/notify.json"
        printf 'Y\n\n\n\n\n' | HOME="$codex_home" bash "${repo_root}/install/codex.sh" >/dev/null
        [ -f "${codex_home}/.codex/codex-push-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} codex: canonical config was not written"; return 1; }
        grep -q "legacy-bark-key" "${codex_home}/.codex/codex-push-hooks/notify.json" \
            || { echo -e "${RED}[Install Smoke]${NC} codex: legacy credentials were not reused"; return 1; }
        [ -f "${codex_home}/.codex/cc-notify-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} codex: legacy config was destroyed"; return 1; }
        grep -q "notify.sh notification" "${codex_home}/.codex/hooks.json" \
            || { echo -e "${RED}[Install Smoke]${NC} codex: hooks.json was not written"; return 1; }
        echo -e "  codex installer reuses legacy config into the canonical path ✅"

        # ---- Reasonix: legacy config is reused; plugin registration is stubbed ----
        stubbin="${tmp_root}/stubbin"
        mkdir -p "$stubbin"
        printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = "hook" ]; then printf "%s\n" "{\"hooks\":[]}"; fi' 'exit 0' \
            > "${stubbin}/reasonix"
        chmod +x "${stubbin}/reasonix"
        reasonix_home="${tmp_root}/reasonix-home"
        mkdir -p "${reasonix_home}/.reasonix/cc-notify-hooks"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-reasonix-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${reasonix_home}/.reasonix/cc-notify-hooks/notify.json"
        printf 'Y\n\n\n\n\n' | HOME="$reasonix_home" PATH="${stubbin}:$PATH" bash "${repo_root}/install/reasonix.sh" >/dev/null
        [ -f "${reasonix_home}/.reasonix/codex-push-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} reasonix: canonical config was not written"; return 1; }
        grep -q "legacy-reasonix-key" "${reasonix_home}/.reasonix/codex-push-hooks/notify.json" \
            || { echo -e "${RED}[Install Smoke]${NC} reasonix: legacy credentials were not reused"; return 1; }
        [ -f "${reasonix_home}/.reasonix/cc-notify-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} reasonix: legacy config was destroyed"; return 1; }
        echo -e "  reasonix installer reuses legacy config into the canonical path ✅"

        # ---- dsh: legacy config reused, legacy link removed, legacy entry migrated ----
        dsh_home="${tmp_root}/dsh-home"
        mkdir -p "${dsh_home}/.dsh/cc-notify-hooks" "${dsh_home}/node_modules/@dsh-local"
        mkdir -p "${dsh_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-dsh-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${dsh_home}/.dsh/cc-notify-hooks/notify.json"
        printf '%s\n' '- insert:' '    - id: cc-notify-hooks' "      name: '@dsh-local/dsh-cc-notify'" '      config:' '        scriptsDir: /old/clone/plugins/cc-notify-hooks/scripts' '        stateDir: /old/state' \
            > "${dsh_home}/.dsh/cordis.patch.yml"
        ln -s "${dsh_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin" "${dsh_home}/node_modules/@dsh-local/dsh-cc-notify"
        printf 'Y\n\n\n\n\n' | HOME="$dsh_home" bash "${repo_root}/install/dsh.sh" >/dev/null
        [ -f "${dsh_home}/.dsh/codex-push-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical config was not written"; return 1; }
        grep -q "legacy-dsh-key" "${dsh_home}/.dsh/codex-push-hooks/notify.json" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy credentials were not reused"; return 1; }
        [ -f "${dsh_home}/.dsh/cc-notify-hooks/notify.json" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy config was destroyed"; return 1; }
        [ -e "${dsh_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical plugin link is missing"; return 1; }
        if [ "$have_symlinks" = "1" ]; then
            [ -L "${dsh_home}/node_modules/@dsh-local/codex-push-hooks" ] \
                || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical plugin link is not a symlink"; return 1; }
            [ ! -L "${dsh_home}/node_modules/@dsh-local/dsh-cc-notify" ] \
                || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy plugin link is still present"; return 1; }
        else
            echo -e "  (no real symlinks on this machine; skipping symlink-type assertions)"
        fi
        [ "$(grep -c "id: codex-push-hooks" "${dsh_home}/.dsh/cordis.patch.yml")" = "1" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: expected exactly one canonical insert entry"; return 1; }
        grep -q "id: cc-notify-hooks" "${dsh_home}/.dsh/cordis.patch.yml" \
            && { echo -e "${RED}[Install Smoke]${NC} dsh: legacy insert entry is still present"; return 1; }
        grep -q "@dsh-local/codex-push-hooks" "${dsh_home}/.dsh/cordis.patch.yml" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: migrated entry has the wrong package name"; return 1; }
        grep -q "plugins/codex-push-hooks/scripts" "${dsh_home}/.dsh/cordis.patch.yml" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: migrated entry has the wrong scriptsDir"; return 1; }
        echo -e "  dsh installer migrates the legacy entry without duplicating ✅"

        # ---- dsh rerun is idempotent: no duplicate entry ----
        printf '\n\n\n\n\n' | HOME="$dsh_home" bash "${repo_root}/install/dsh.sh" >/dev/null
        [ "$(grep -c "id: codex-push-hooks" "${dsh_home}/.dsh/cordis.patch.yml")" = "1" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: rerun duplicated the insert entry"; return 1; }
        echo -e "  dsh installer rerun stays idempotent ✅"

        link_intact() {
            # $1 = path that must still exist (as a symlink where supported)
            if [ "$have_symlinks" = "1" ]; then
                [ -L "$1" ] || return 1
            else
                [ -e "$1" ] || return 1
            fi
            return 0
        }

        # ---- dsh B: unexpected legacy shape fails without changing anything ----
        dsh_bad_home="${tmp_root}/dsh-bad-home"
        mkdir -p "${dsh_bad_home}/.dsh/cc-notify-hooks" "${dsh_bad_home}/node_modules/@dsh-local"
        mkdir -p "${dsh_bad_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-dsh-bad-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${dsh_bad_home}/.dsh/cc-notify-hooks/notify.json"
        printf '%s\n' '- insert:' '    - id: cc-notify-hooks' "      name: 'some-other-package'" '      config:' '        scriptsDir: /old/custom/scripts' '        stateDir: /old/state' \
            > "${dsh_bad_home}/.dsh/cordis.patch.yml"
        cp "${dsh_bad_home}/.dsh/cordis.patch.yml" "${dsh_bad_home}/.dsh/cordis.patch.yml.before"
        ln -s "${dsh_bad_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin" "${dsh_bad_home}/node_modules/@dsh-local/dsh-cc-notify"
        if printf 'Y\n\n\n\n\n' | HOME="$dsh_bad_home" bash "${repo_root}/install/dsh.sh" >/dev/null 2>"${tmp_root}/dsh-bad.log"; then
            echo -e "${RED}[Install Smoke]${NC} dsh: unexpected-shape migration should have failed"
            return 1
        fi
        cmp -s "${dsh_bad_home}/.dsh/cordis.patch.yml" "${dsh_bad_home}/.dsh/cordis.patch.yml.before" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: patch file was mutated on failed migration"; return 1; }
        link_intact "${dsh_bad_home}/node_modules/@dsh-local/dsh-cc-notify" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy link was removed on failed migration"; return 1; }
        [ ! -e "${dsh_bad_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical link was created on failed migration"; return 1; }
        grep -q "id: codex-push-hooks" "${dsh_bad_home}/.dsh/cordis.patch.yml" \
            && { echo -e "${RED}[Install Smoke]${NC} dsh: canonical entry was partially created"; return 1; }
        echo -e "  dsh installer refuses an unexpected legacy shape without changing anything ✅"

        # ---- dsh C: canonical + legacy entries already present fails safely ----
        dsh_dup_home="${tmp_root}/dsh-dup-home"
        mkdir -p "${dsh_dup_home}/.dsh/cc-notify-hooks" "${dsh_dup_home}/node_modules/@dsh-local"
        mkdir -p "${dsh_dup_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-dsh-dup-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${dsh_dup_home}/.dsh/cc-notify-hooks/notify.json"
        printf '%s\n' '- insert:' '    - id: codex-push-hooks' "      name: '@dsh-local/codex-push-hooks'" '      config:' '        scriptsDir: /repo/plugins/codex-push-hooks/scripts' '        stateDir: /repo/state' '- insert:' '    - id: cc-notify-hooks' "      name: '@dsh-local/dsh-cc-notify'" '      config:' '        scriptsDir: /old/clone/plugins/cc-notify-hooks/scripts' '        stateDir: /old/state' \
            > "${dsh_dup_home}/.dsh/cordis.patch.yml"
        cp "${dsh_dup_home}/.dsh/cordis.patch.yml" "${dsh_dup_home}/.dsh/cordis.patch.yml.before"
        ln -s "${dsh_dup_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin" "${dsh_dup_home}/node_modules/@dsh-local/dsh-cc-notify"
        if printf 'Y\n\n\n\n\n' | HOME="$dsh_dup_home" bash "${repo_root}/install/dsh.sh" >/dev/null 2>"${tmp_root}/dsh-dup.log"; then
            echo -e "${RED}[Install Smoke]${NC} dsh: duplicate registration should have failed"
            return 1
        fi
        cmp -s "${dsh_dup_home}/.dsh/cordis.patch.yml" "${dsh_dup_home}/.dsh/cordis.patch.yml.before" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: patch file was mutated on duplicate stop"; return 1; }
        link_intact "${dsh_dup_home}/node_modules/@dsh-local/dsh-cc-notify" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy link was removed on duplicate stop"; return 1; }
        [ ! -e "${dsh_dup_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical link was created on duplicate stop"; return 1; }
        [ "$(grep -c "id: codex-push-hooks" "${dsh_dup_home}/.dsh/cordis.patch.yml")" = "1" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: canonical entry count changed on duplicate stop"; return 1; }
        grep -q "id: cc-notify-hooks" "${dsh_dup_home}/.dsh/cordis.patch.yml" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy entry vanished on duplicate stop"; return 1; }
        echo -e "  dsh installer stops on duplicate old/new registration ✅"

        # ---- dsh E: a comment mentioning an id is not a real entry ----
        dsh_comment_home="${tmp_root}/dsh-comment-home"
        mkdir -p "${dsh_comment_home}/.dsh/cc-notify-hooks" "${dsh_comment_home}/node_modules/@dsh-local"
        mkdir -p "${dsh_comment_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin"
        printf '%s\n' '{"channels":{"bark":{"enabled":true,"delay":15,"key":"legacy-dsh-comment-key","server":"https://api.day.app"}},"rate_limit":10}' \
            > "${dsh_comment_home}/.dsh/cc-notify-hooks/notify.json"
        printf '%s\n' '# historical example - id: codex-push-hooks (must never count as an entry)' '- insert:' '    - id: cc-notify-hooks' "      name: '@dsh-local/dsh-cc-notify'" '      config:' '        scriptsDir: /old/clone/plugins/cc-notify-hooks/scripts' '        stateDir: /old/state' \
            > "${dsh_comment_home}/.dsh/cordis.patch.yml"
        ln -s "${dsh_comment_home}/old-clone/plugins/cc-notify-hooks/dsh-plugin" "${dsh_comment_home}/node_modules/@dsh-local/dsh-cc-notify"
        printf 'Y\n\n\n\n\n' | HOME="$dsh_comment_home" bash "${repo_root}/install/dsh.sh" >/dev/null
        [ "$(grep -cE "^[[:space:]]*- id: codex-push-hooks[[:space:]]*$" "${dsh_comment_home}/.dsh/cordis.patch.yml")" = "1" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: comment confused entry detection"; return 1; }
        ! grep -qE "^[[:space:]]*- id: cc-notify-hooks[[:space:]]*$" "${dsh_comment_home}/.dsh/cordis.patch.yml" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy entry was not migrated past the comment"; return 1; }
        grep -q "historical example" "${dsh_comment_home}/.dsh/cordis.patch.yml" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: comment line was damaged by migration"; return 1; }
        if [ "$have_symlinks" = "1" ]; then
            [ ! -L "${dsh_comment_home}/node_modules/@dsh-local/dsh-cc-notify" ] \
                || { echo -e "${RED}[Install Smoke]${NC} dsh: legacy link kept after comment-case migration"; return 1; }
        fi
        echo -e "  dsh installer ignores comment-only id mentions ✅"

        # ---- dsh F: canonical path is a regular file -> refuse, keep it intact ----
        dsh_file_home="${tmp_root}/dsh-file-home"
        mkdir -p "${dsh_file_home}/node_modules/@dsh-local"
        printf '%s\n' 'precious user content' > "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks"
        cp "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks" "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks.before"
        if printf '\n\n\n\n' | HOME="$dsh_file_home" bash "${repo_root}/install/dsh.sh" >/dev/null 2>"${tmp_root}/dsh-file.log"; then
            echo -e "${RED}[Install Smoke]${NC} dsh: real file at the link path should have failed"
            return 1
        fi
        [ -f "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: real file vanished"; return 1; }
        [ ! -L "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: real file was replaced by a symlink"; return 1; }
        cmp -s "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks" "${dsh_file_home}/node_modules/@dsh-local/codex-push-hooks.before" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: real file contents changed"; return 1; }
        [ ! -e "${dsh_file_home}/.dsh/cordis.patch.yml" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: patch file was touched on link-guard failure"; return 1; }
        echo -e "  dsh installer refuses a real file at the managed link path ✅"

        # ---- dsh G: canonical path is a real directory -> refuse, keep it intact ----
        dsh_dir_home="${tmp_root}/dsh-dir-home"
        mkdir -p "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks"
        printf '%s\n' 'precious user content' > "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks/marker.txt"
        cp "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks/marker.txt" "${dsh_dir_home}/node_modules/@dsh-local/marker.txt.before"
        if printf '\n\n\n\n' | HOME="$dsh_dir_home" bash "${repo_root}/install/dsh.sh" >/dev/null 2>"${tmp_root}/dsh-dir.log"; then
            echo -e "${RED}[Install Smoke]${NC} dsh: real directory at the link path should have failed"
            return 1
        fi
        [ -d "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: real directory vanished"; return 1; }
        [ ! -L "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: real directory was replaced by a symlink"; return 1; }
        cmp -s "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks/marker.txt" "${dsh_dir_home}/node_modules/@dsh-local/marker.txt.before" \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: directory contents changed"; return 1; }
        [ ! -e "${dsh_dir_home}/node_modules/@dsh-local/codex-push-hooks/dsh-plugin" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: nested symlink created inside the real directory"; return 1; }
        [ ! -e "${dsh_dir_home}/.dsh/cordis.patch.yml" ] \
            || { echo -e "${RED}[Install Smoke]${NC} dsh: patch file was touched on link-guard failure"; return 1; }
        echo -e "  dsh installer refuses a real directory at the managed link path ✅"

        echo -e "${GREEN}[Install Smoke]${NC} ✅ canonical paths and legacy migration behave as expected"
    )
}

# Main dispatch
case "$COMMAND" in
    list)
        list_channels
        ;;
    hook)
        test_hook_flow
        ;;
    codex)
        test_codex_flow
        ;;
    codex-plugin-hooks)
        test_codex_plugin_hooks
        ;;
    user-input)
        test_user_input_flow
        ;;
    state)
        test_session_state
        ;;
    render)
        test_render_templates
        ;;
    agents)
        test_agent_detection
        ;;
    config-paths)
        test_config_paths
        ;;
    install-smoke)
        test_install_smoke
        ;;
    all)
        for ch_file in "${CHANNELS_DIR}"/*.sh; do
            name=$(basename "$ch_file" .sh)
            test_channel "$name"
            echo ""
        done
        ;;
    *)
        test_channel "$1"
        ;;
esac

echo ""
echo "========================================="
