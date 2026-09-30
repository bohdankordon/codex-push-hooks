#!/usr/bin/env bash
#
# cc-notify-hooks standalone install script (Codex CLI branch)
# Deploys scripts/ to ~/.codex/cc-notify-hooks/ and writes ~/.codex/hooks.json
#
# Can be called by the install.sh router or run on its own:
#   bash install/codex.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
INSTALL_DIR="${CODEX_HOME}/cc-notify-hooks"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
STATE_DIR="${HOME}/.claude/hooks/state"  # reuse Claude's state directory so both can coexist
CONFIG_FILE="${INSTALL_DIR}/notify.json"
HOOKS_FILE="${CODEX_HOME}/hooks.json"
CODEX_CONFIG="${CODEX_HOME}/config.toml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true

echo "========================================="
echo "  cc-notify-hooks - Codex CLI standalone install"
echo "  Platform: $(uname -s) $(uname -m)"
echo "========================================="
echo ""

# ============================================================
#  [1/4] Check dependencies
# ============================================================
echo -e "${YELLOW}[1/4]${NC} checking dependencies..."
MISSING_DEP=0
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "  ${RED}✗${NC} $cmd is not installed"
        MISSING_DEP=1
    else
        echo -e "  ${GREEN}✓${NC} $cmd"
    fi
done
if [ "$MISSING_DEP" -eq 1 ]; then
    echo ""
    echo "  Install the missing dependencies first:"
    if $IS_MACOS; then
        echo "  macOS:         brew install jq curl"
    else
        echo "  Debian/Ubuntu: sudo apt install -y jq curl"
        echo "  CentOS/RHEL:   sudo yum install -y jq curl"
    fi
    exit 1
fi

# Codex install hint (not enforced; hooks can be installed first)
if ! command -v codex &>/dev/null && [ ! -x "/Applications/Codex.app/Contents/Resources/codex" ]; then
    echo -e "  ${YELLOW}⚠${NC} Codex CLI not detected (continuing; install Codex later)"
fi

# ============================================================
#  [2/4] Interactive configuration
# ============================================================
echo -e "${YELLOW}[2/4]${NC} configuring push channels..."
echo ""

# Channel definitions: name|display_name|default_delay|credential_fields
CHANNEL_DEFS=(
    "macos|macOS system notification|3|"
    "bark|Bark (iOS/macOS/Android)|15|key:Bark Key;server:Bark Server [https://api.day.app]"
    "telegram|Telegram Bot|5|bot_token:Bot Token;chat_id:Chat ID"
    "pushover|Pushover|15|app_token:App Token;user_key:User Key"
    "ntfy|ntfy (open-source push)|15|topic:Topic;server:Server [https://ntfy.sh]"
    "gotify|Gotify (self-hosted push)|15|server:Server URL;app_token:App Token"
    "wechat|WeCom|300|webhook:Webhook URL"
    "feishu|Feishu|300|webhook:Webhook URL"
    "dingtalk|DingTalk|300|webhook:Webhook URL"
    "slack|Slack|300|webhook:Webhook URL"
    "discord|Discord|300|webhook:Webhook URL"
)

_read_json() {
    local key="$1" default="$2"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null) || true
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# Reuse the Claude configuration when one already exists
CLAUDE_CONFIG="${HOME}/.claude/hooks/notify.json"
if [ ! -f "$CONFIG_FILE" ] && [ -f "$CLAUDE_CONFIG" ]; then
    echo -e "  ${CYAN}Detected a Claude Code configuration that can be reused${NC}"
    printf "  Reuse $CLAUDE_CONFIG? [Y/n]: "
    read -r reuse
    if [[ ! "$reuse" =~ ^[Nn] ]]; then
        mkdir -p "$INSTALL_DIR"
        cp "$CLAUDE_CONFIG" "$CONFIG_FILE"
        echo -e "  ${GREEN}✓${NC} reused the Claude configuration"
        echo ""
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${CYAN}Existing configuration detected ($CONFIG_FILE)${NC}"
    echo ""
fi

# List the channels for the user to choose from
echo "  Available notification channels:"
echo ""
idx=1
for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay _fields <<< "$def"
    current_enabled=$(_read_json ".channels.${name}.enabled" "false")
    if [ "$current_enabled" = "true" ]; then
        mark="${GREEN}✓${NC}"
    else
        mark=" "
    fi
    if [ "$name" = "macos" ] && $IS_MACOS && [ "$current_enabled" = "false" ] && [ ! -f "$CONFIG_FILE" ]; then
        mark="${GREEN}✓${NC}"
    fi
    printf "  %s [%b] %2d. %-30s (default delay %ss)\n" "" "$mark" "$idx" "$display" "$delay"
    idx=$((idx + 1))
done
echo ""
echo -e "  ${CYAN}Enter the numbers of the channels to enable (comma-separated, e.g. 1,2,7); press Enter to keep the current configuration${NC}"

printf "  Choose: "
read -r selection

declare -A ENABLED_CHANNELS=()
if [ -n "$selection" ]; then
    IFS=',' read -ra NUMS <<< "$selection"
    for num in "${NUMS[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#CHANNEL_DEFS[@]} ]; then
            IFS='|' read -r name _ _ _ <<< "${CHANNEL_DEFS[$((num - 1))]}"
            ENABLED_CHANNELS["$name"]=1
        fi
    done
else
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r name; do
            ENABLED_CHANNELS["$name"]=1
        done < <(jq -r '.channels // {} | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null)
    fi
    if $IS_MACOS && [ ${#ENABLED_CHANNELS[@]} -eq 0 ]; then
        ENABLED_CHANNELS["macos"]=1
    fi
fi

echo ""

# Collect credentials
declare -A CHANNEL_CONFIGS=()

for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay fields <<< "$def"

    if [ "${ENABLED_CHANNELS[$name]:-}" != "1" ]; then
        continue
    fi
    if [ -z "$fields" ]; then
        continue
    fi

    echo -e "  ${CYAN}Configuring ${display}:${NC}"

    IFS=';' read -ra FIELD_DEFS <<< "$fields"
    for fdef in "${FIELD_DEFS[@]}"; do
        IFS=':' read -r fkey fdesc <<< "$fdef"

        default_hint=""
        if [[ "$fdesc" =~ \[(.+)\] ]]; then
            default_hint="${BASH_REMATCH[1]}"
            fdesc=$(echo "$fdesc" | sed 's/ *\[.*\]//')
        fi

        current=$(_read_json ".channels.${name}.${fkey}" "$default_hint")
        if [ -n "$current" ]; then
            if [ ${#current} -gt 20 ]; then
                hint="${current:0:20}..."
            else
                hint="$current"
            fi
        else
            hint="required"
        fi

        printf "    %s [%s]: " "$fdesc" "$hint"
        read -r input
        CHANNEL_CONFIGS["${name}.${fkey}"]="${input:-$current}"
    done
    echo ""
done

# Build the configuration JSON
CONFIG_JSON='{"channels":{},"rate_limit":10}'

if [ -f "$CONFIG_FILE" ]; then
    old_rate=$(jq -r '.rate_limit // 10' "$CONFIG_FILE")
    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --argjson rl "$old_rate" '.rate_limit = $rl')
fi

for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay fields <<< "$def"

    enabled="false"
    [ "${ENABLED_CHANNELS[$name]:-}" = "1" ] && enabled="true"

    ch_json=$(jq -n --argjson enabled "$enabled" --argjson delay "$delay" '{enabled: $enabled, delay: $delay}')

    if [ "$name" = "macos" ]; then
        ch_json=$(echo "$ch_json" | jq '. + {sound: "Glass", events: ["notification"]}')
    fi

    if [ -n "$fields" ]; then
        IFS=';' read -ra FIELD_DEFS <<< "$fields"
        for fdef in "${FIELD_DEFS[@]}"; do
            IFS=':' read -r fkey fdesc <<< "$fdef"
            val="${CHANNEL_CONFIGS["${name}.${fkey}"]:-}"

            if [ -z "$val" ] && [ -f "$CONFIG_FILE" ]; then
                val=$(jq -r ".channels.\"${name}\".\"${fkey}\" // empty" "$CONFIG_FILE" 2>/dev/null) || true
            fi

            if [ -z "$val" ] && [[ "$fdesc" =~ \[(.+)\] ]]; then
                val="${BASH_REMATCH[1]}"
            fi

            if [ -n "$val" ]; then
                ch_json=$(echo "$ch_json" | jq --arg v "$val" --arg k "$fkey" '.[$k] = $v')
            fi
        done
    fi

    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --argjson ch "$ch_json" --arg name "$name" '.channels[$name] = $ch')
done

mkdir -p "$INSTALL_DIR"
echo "$CONFIG_JSON" | jq '.' > "$CONFIG_FILE"
echo -e "  ${GREEN}✓${NC} configuration written to $CONFIG_FILE"

# ============================================================
#  [3/4] Install the scripts
# ============================================================
echo -e "${YELLOW}[3/4]${NC} installing scripts..."
mkdir -p "$STATE_DIR" "$SCRIPTS_DIR/channels" "$SCRIPTS_DIR/lib"
cp "$REPO_ROOT/scripts/notify.sh" "$SCRIPTS_DIR/notify.sh"
cp "$REPO_ROOT/scripts/clear_pending.sh" "$SCRIPTS_DIR/clear_pending.sh"
cp "$REPO_ROOT/scripts/pre_tool_use.sh" "$SCRIPTS_DIR/pre_tool_use.sh"
cp "$REPO_ROOT/scripts/channels/"*.sh "$SCRIPTS_DIR/channels/"
cp "$REPO_ROOT/scripts/lib/"*.sh "$SCRIPTS_DIR/lib/"
chmod +x \
    "$SCRIPTS_DIR/notify.sh" \
    "$SCRIPTS_DIR/clear_pending.sh" \
    "$SCRIPTS_DIR/pre_tool_use.sh" \
    "$SCRIPTS_DIR/channels/"*.sh
echo -e "  ${GREEN}✓${NC} scripts copied to $SCRIPTS_DIR"

# Help notify.sh find the Codex-mode configuration
# notify.sh already supports ~/.claude/hooks/notify.json; this keeps another copy under the Codex path
# CC_NOTIFY_CONFIG lets the script find the Codex configuration (the script already supports an environment override)
# Actual approach: set the environment variable through sh -c inside the hooks.json command and then call the script

# ============================================================
#  [4/4] Write ~/.codex/hooks.json
# ============================================================
echo -e "${YELLOW}[4/4]${NC} writing hooks.json..."

# Call the scripts with absolute paths; notify.sh reads its configuration from ~/.codex/cc-notify-hooks/notify.json
HOOKS_JSON=$(jq -n --arg s "$SCRIPTS_DIR" '
{
  hooks: {
    PermissionRequest: [{
      matcher: "*",
      hooks: [{type: "command", command: ($s + "/notify.sh notification"), timeout: 5}]
    }],
    Stop: [{
      matcher: "*",
      hooks: [{type: "command", command: ($s + "/notify.sh stop"), timeout: 5}]
    }],
    UserPromptSubmit: [{
      matcher: "*",
      hooks: [{type: "command", command: ($s + "/clear_pending.sh"), timeout: 3}]
    }],
    PreToolUse: [{
      matcher: "*",
      hooks: [{type: "command", command: ($s + "/pre_tool_use.sh"), timeout: 3}]
    }],
    PostToolUse: [{
      matcher: "^request_user_input$",
      hooks: [{type: "command", command: ($s + "/clear_pending.sh user_input"), timeout: 3}]
    }]
  }
}')

mkdir -p "$CODEX_HOME"
if [ -f "$HOOKS_FILE" ]; then
    BACKUP="${HOOKS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$HOOKS_FILE" "$BACKUP"
    echo "  backed up the original hooks.json to: $BACKUP"

    # Merge: this plugin's hooks replace events with the same name and keep all other events
    jq -s '.[0] * .[1]' "$HOOKS_FILE" <(echo "$HOOKS_JSON") \
        > "${HOOKS_FILE}.tmp" \
        && mv "${HOOKS_FILE}.tmp" "$HOOKS_FILE"
    echo -e "  ${GREEN}✓${NC} hooks merged into $HOOKS_FILE"
else
    echo "$HOOKS_JSON" | jq '.' > "$HOOKS_FILE"
    echo -e "  ${GREEN}✓${NC} $HOOKS_FILE created"
fi

# ============================================================
#  Check whether hooks are enabled (accepts both the codex_hooks and hooks names)
# ============================================================
HOOKS_ENABLED=false
if [ -f "$CODEX_CONFIG" ]; then
    if grep -qE '^[[:space:]]*(codex_)?hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG"; then
        HOOKS_ENABLED=true
    fi
fi

# ============================================================
#  Summary
# ============================================================
echo ""
ENABLED_COUNT=0
for name in "${!ENABLED_CHANNELS[@]}"; do
    [ "${ENABLED_CHANNELS[$name]}" = "1" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
done

if [ "$ENABLED_COUNT" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} no push channel is enabled"
else
    echo "  Enabled channels:"
    for def in "${CHANNEL_DEFS[@]}"; do
        IFS='|' read -r name display delay _ <<< "$def"
        if [ "${ENABLED_CHANNELS[$name]:-}" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ${display} (delay ${delay}s)"
        fi
    done
fi

echo ""
echo "========================================="
echo -e "  ${GREEN}✅ Installation complete!${NC}"
echo ""

if ! $HOOKS_ENABLED; then
    echo -e "  ${RED}${BOLD}⚠ Important: Codex hooks must be enabled manually${NC}"
    echo ""
    echo "  Add the following to $CODEX_CONFIG:"
    echo ""
    echo -e "    ${CYAN}[features]${NC}"
    echo -e "    ${CYAN}codex_hooks = true${NC}"
    echo ""
    echo "  Save the file; it takes effect the next time Codex starts."
    echo ""
else
    echo -e "  ${GREEN}✓${NC} codex_hooks is already enabled in $CODEX_CONFIG"
    echo ""
fi

echo "  Next steps:"
echo "  1. Test: bash $REPO_ROOT/test_notify.sh"
echo "  2. Restart Codex so the hooks take effect"
echo "  3. Debug: tail -f /tmp/claude-hooks-debug.log"
echo ""
echo "  Change the configuration: edit $CONFIG_FILE"
echo "========================================="
