#!/usr/bin/env bash
#
# cc-notify-hooks standalone install script (Reasonix branch)
# Writes the configuration to ~/.reasonix/cc-notify-hooks/notify.json and
# registers the plugin with Reasonix in --link mode (reasonix plugin install).
#
# Can be called by the install.sh router or run on its own:
#   bash install/reasonix.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="${REPO_ROOT}/plugins/cc-notify-hooks"
REASONIX_HOME_DIR="${REASONIX_HOME:-${HOME}/.reasonix}"
INSTALL_DIR="${REASONIX_HOME_DIR}/cc-notify-hooks"
CONFIG_FILE="${INSTALL_DIR}/notify.json"
STATE_DIR="${HOME}/.claude/hooks/state"  # shared state directory for all agents

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true

echo "========================================="
echo "  cc-notify-hooks - Reasonix standalone install"
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

if ! command -v reasonix &>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} reasonix CLI not detected (continuing; install Reasonix later)"
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

# Reuse an existing configuration (Claude / Codex) so credentials are not entered twice
if [ ! -f "$CONFIG_FILE" ]; then
    for existing in \
        "${HOME}/.claude/hooks/notify.json" \
        "${CODEX_HOME:-${HOME}/.codex}/cc-notify-hooks/notify.json"; do
        if [ -f "$existing" ]; then
            echo -e "  ${CYAN}Existing configuration detected; it can be reused${NC}"
            printf "  Reuse $existing? [Y/n]: "
            read -r reuse
            if [[ ! "$reuse" =~ ^[Nn] ]]; then
                mkdir -p "$INSTALL_DIR"
                cp "$existing" "$CONFIG_FILE"
                echo -e "  ${GREEN}✓${NC} reused the configuration"
                echo ""
            fi
            break
        fi
    done
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
#  [3/4] Register the plugin with Reasonix
# ============================================================
echo -e "${YELLOW}[3/4]${NC} registering the plugin with Reasonix (--link points at this repository)..."
mkdir -p "$STATE_DIR"

reasonix plugin install "$PLUGIN_DIR" --link --replace --yes >/dev/null

HOOK_COUNT=$(reasonix hook list --json 2>/dev/null | jq -r '.hooks | length' 2>/dev/null || echo "?")
echo -e "  ${GREEN}✓${NC} plugin registered; Reasonix loaded ${HOOK_COUNT} hooks"

# ============================================================
#  [4/4] Summary
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
echo "  2. Restart the Reasonix session so the hooks take effect (/new does not reload them)"
echo "  3. Debug: tail -f /tmp/claude-hooks-debug.log"
echo ""
echo "  Event mapping:"
echo "    Notification       → push while waiting for tool approval (approval needed 🔔)"
echo "    Stop               → push when a conversation turn ends (task complete ✅)"
echo "    UserPromptSubmit   → cancel queued pushes once the user responds"
echo "    PreToolUse(ask)    → push when a question is asked (reply needed 🔔); other tools clear pending"
echo ""
echo "  Manage: reasonix plugin show cc-notify-hooks"
echo "  Uninstall: reasonix plugin remove cc-notify-hooks --yes"
echo "  Change the configuration: edit $CONFIG_FILE"
echo "========================================="
