#!/usr/bin/env bash
#
# cc-notify-hooks standalone install script (Claude Code branch)
# Deploys scripts/ to ~/.claude/hooks/ and merges the hook configuration into ~/.claude/settings.json
#
# Can be called by the install.sh router or run on its own:
#   bash install/claude.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="${HOME}/.claude/hooks"
SCRIPTS_DIR="${HOOKS_DIR}/scripts"
STATE_DIR="${HOOKS_DIR}/state"
CONFIG_FILE="${HOOKS_DIR}/notify.json"
SETTINGS_FILE="${HOME}/.claude/settings.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true

echo "========================================="
echo "  cc-notify-hooks - Claude Code standalone install"
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

# Read the existing configuration
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

if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${CYAN}Existing configuration detected ($CONFIG_FILE)${NC}"
    echo ""
fi

# Migrate a legacy configuration
if [ -f "${HOOKS_DIR}/notify.conf" ] && [ ! -f "$CONFIG_FILE" ]; then
    echo -e "  ${CYAN}Detected a v1 configuration (notify.conf); migrating automatically${NC}"
    # Read the old configuration
    source "${HOOKS_DIR}/notify.conf"
    # Build the base JSON
    MIGRATE_JSON=$(jq -n \
        --arg bark_key "${BARK_KEY:-}" \
        --arg bark_server "${BARK_SERVER:-https://api.day.app}" \
        --arg qywx_webhook "${QYWX_WEBHOOK:-}" \
        --argjson bark_delay "${BARK_DELAY:-15}" \
        --argjson wechat_delay "${WECHAT_DELAY:-300}" \
        --argjson rate_limit "${RATE_LIMIT:-10}" \
        '{
            channels: {
                macos: {enabled: true, delay: 3, sound: "Glass", events: ["notification"]},
                bark: {enabled: ($bark_key != ""), delay: $bark_delay, key: $bark_key, server: $bark_server},
                wechat: {enabled: ($qywx_webhook != ""), delay: $wechat_delay, webhook: $qywx_webhook}
            },
            rate_limit: $rate_limit
        }')
    echo "$MIGRATE_JSON" > "$CONFIG_FILE"
    mv "${HOOKS_DIR}/notify.conf" "${HOOKS_DIR}/notify.conf.bak"
    echo -e "  ${GREEN}✓${NC} migrated; the old configuration was backed up to notify.conf.bak"
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
    # macOS is enabled by default on macOS
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

# Parse the selection
declare -A ENABLED_CHANNELS
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
    # Keep the current configuration
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r name; do
            ENABLED_CHANNELS["$name"]=1
        done < <(jq -r '.channels // {} | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null)
    fi
    # macOS fallback
    if $IS_MACOS && [ ${#ENABLED_CHANNELS[@]} -eq 0 ]; then
        ENABLED_CHANNELS["macos"]=1
    fi
fi

echo ""

# Collect credentials for every enabled channel
declare -A CHANNEL_CONFIGS

for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay fields <<< "$def"

    if [ "${ENABLED_CHANNELS[$name]:-}" != "1" ]; then
        continue
    fi

    if [ -z "$fields" ]; then
        # Channels without credentials (macOS)
        continue
    fi

    echo -e "  ${CYAN}Configuring ${display}:${NC}"

    IFS=';' read -ra FIELD_DEFS <<< "$fields"
    for fdef in "${FIELD_DEFS[@]}"; do
        IFS=':' read -r fkey fdesc <<< "$fdef"

        # Extract the default-value hint
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

# Build the JSON configuration
CONFIG_JSON='{"channels":{},"rate_limit":10}'

# Read the existing rate_limit
if [ -f "$CONFIG_FILE" ]; then
    old_rate=$(jq -r '.rate_limit // 10' "$CONFIG_FILE")
    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --argjson rl "$old_rate" '.rate_limit = $rl')
fi

for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay fields <<< "$def"

    enabled="false"
    [ "${ENABLED_CHANNELS[$name]:-}" = "1" ] && enabled="true"

    # Build the channel object
    ch_json=$(jq -n --argjson enabled "$enabled" --argjson delay "$delay" '{enabled: $enabled, delay: $delay}')

    # macOS-specific fields
    if [ "$name" = "macos" ]; then
        ch_json=$(echo "$ch_json" | jq '. + {sound: "Glass", events: ["notification"]}')
    fi

    # Add the credential fields
    if [ -n "$fields" ]; then
        IFS=';' read -ra FIELD_DEFS <<< "$fields"
        for fdef in "${FIELD_DEFS[@]}"; do
            IFS=':' read -r fkey fdesc <<< "$fdef"
            val="${CHANNEL_CONFIGS["${name}.${fkey}"]:-}"

            # Try to read from the existing configuration
            if [ -z "$val" ] && [ -f "$CONFIG_FILE" ]; then
                val=$(jq -r ".channels.\"${name}\".\"${fkey}\" // empty" "$CONFIG_FILE" 2>/dev/null) || true
            fi

            # Extract the default value in square brackets
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

# Write the configuration file
mkdir -p "$HOOKS_DIR"
echo "$CONFIG_JSON" | jq '.' > "$CONFIG_FILE"
echo -e "  ${GREEN}✓${NC} configuration written to $CONFIG_FILE"

# ============================================================
#  [3/4] Install the scripts
# ============================================================
echo -e "${YELLOW}[3/4]${NC} installing scripts..."
mkdir -p "$STATE_DIR" "$SCRIPTS_DIR/channels"
cp "$REPO_ROOT/scripts/notify.sh" "$SCRIPTS_DIR/notify.sh"
cp "$REPO_ROOT/scripts/clear_pending.sh" "$SCRIPTS_DIR/clear_pending.sh"
cp "$REPO_ROOT/scripts/channels/"*.sh "$SCRIPTS_DIR/channels/"
chmod +x "$SCRIPTS_DIR/notify.sh" "$SCRIPTS_DIR/clear_pending.sh" "$SCRIPTS_DIR/channels/"*.sh
echo -e "  ${GREEN}✓${NC} scripts copied to $SCRIPTS_DIR"

# ============================================================
#  [4/4] Configure hooks
# ============================================================
echo -e "${YELLOW}[4/4]${NC} configuring hooks..."

# Generate the hooks JSON, replacing paths with the actual install paths
HOOKS_JSON=$(cat "$REPO_ROOT/hooks/hooks.json" | sed "s|\\\${CLAUDE_PLUGIN_ROOT}/scripts|${SCRIPTS_DIR}|g")

if [ -f "$SETTINGS_FILE" ]; then
    BACKUP="${SETTINGS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS_FILE" "$BACKUP"
    echo "  backed up the original configuration to: $BACKUP"

    jq -s '.[0] * {hooks: .[1].hooks}' "$SETTINGS_FILE" <(echo "$HOOKS_JSON") \
        > "${SETTINGS_FILE}.tmp" \
        && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

    echo -e "  ${GREEN}✓${NC} hooks merged into settings.json"
else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo "$HOOKS_JSON" > "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} settings.json created"
fi

# ============================================================
#  Verification
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
echo "  Next steps:"
echo "  1. Test: bash $REPO_ROOT/test_notify.sh"
echo "  2. Restart Claude Code so the hooks take effect"
echo "  3. Debug: tail -f /tmp/claude-hooks-debug.log"
echo ""
echo "  Change the configuration: edit $CONFIG_FILE"
echo "  Plugin mode: claude --plugin-dir $REPO_ROOT/plugins/cc-notify-hooks"
echo "========================================="
