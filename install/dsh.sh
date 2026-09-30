#!/usr/bin/env bash
#
# codex-push-hooks standalone install script (dsh / DeepSeek Harness branch)
# Writes the configuration to ~/.dsh/codex-push-hooks/notify.json,
# symlinks the plugin package into ~/node_modules/@dsh-local/codex-push-hooks,
# and appends an insert entry to ~/.dsh/cordis.patch.yml (hot-loaded, no restart needed).
#
# Can be called by the install.sh router or run on its own:
#   bash install/dsh.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_PKG_DIR="${REPO_ROOT}/plugins/codex-push-hooks/dsh-plugin"
SCRIPTS_DIR="${REPO_ROOT}/plugins/codex-push-hooks/scripts"
DSH_HOME_DIR="${DSH_HOME:-${HOME}/.dsh}"
INSTALL_DIR="${DSH_HOME_DIR}/codex-push-hooks"
CONFIG_FILE="${INSTALL_DIR}/notify.json"
STATE_DIR="${HOME}/.claude/hooks/state"  # shared state directory for all agents
PATCH_FILE="${DSH_HOME_DIR}/cordis.patch.yml"
NODE_MODULES_DIR="${HOME}/node_modules/@dsh-local"
PLUGIN_LINK="${NODE_MODULES_DIR}/codex-push-hooks"
PLUGIN_ENTRY_ID="codex-push-hooks"
# Legacy pre-rebrand identifiers (migration only; never installed fresh).
LEGACY_ENTRY_ID="cc-notify-hooks"
LEGACY_LINK="${NODE_MODULES_DIR}/dsh-cc-notify"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true

echo "========================================="
echo "  codex-push-hooks - dsh standalone install"
echo "  Platform: $(uname -s) $(uname -m)"
echo "========================================="
echo ""

# ============================================================
#  [1/5] Check dependencies
# ============================================================
echo -e "${YELLOW}[1/5]${NC} checking dependencies..."
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

if ! command -v dsh &>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} dsh CLI not detected (continuing; install dsh later)"
fi

# ============================================================
#  [2/5] Interactive configuration
# ============================================================
echo -e "${YELLOW}[2/5]${NC} configuring push channels..."
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

# Reuse an existing configuration (own legacy path first, then Claude / Codex / Reasonix)
# so credentials are not entered twice. Legacy files are copied, never moved or deleted.
if [ ! -f "$CONFIG_FILE" ]; then
    for existing in \
        "${DSH_HOME_DIR}/cc-notify-hooks/notify.json" \
        "${HOME}/.claude/hooks/notify.json" \
        "${CODEX_HOME:-${HOME}/.codex}/codex-push-hooks/notify.json" \
        "${CODEX_HOME:-${HOME}/.codex}/cc-notify-hooks/notify.json" \
        "${REASONIX_HOME:-${HOME}/.reasonix}/codex-push-hooks/notify.json" \
        "${REASONIX_HOME:-${HOME}/.reasonix}/cc-notify-hooks/notify.json"; do
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
#  [3/5] Symlink the plugin package (~/.node_modules resolution path, same as dsh-feishu)
# ============================================================
echo -e "${YELLOW}[3/5]${NC} inspecting the dsh plugin state and linking the package..."

PATCH_BLOCK="
- insert:
    - id: ${PLUGIN_ENTRY_ID}
      name: '@dsh-local/codex-push-hooks'
      config:
        scriptsDir: ${SCRIPTS_DIR}
        stateDir: ${STATE_DIR}"

# Print one patch entry block: the id line plus following lines up to (but
# not including) the next entry boundary or EOF. Entry matching is anchored
# to real YAML list items so comments never count as entries.
print_patch_block() {
    local patch_file="$1"
    local entry_id="$2"
    awk -v id="$entry_id" '
        BEGIN { in_block = 0 }
        $0 ~ "^[[:space:]]*- id: " id "[[:space:]]*$" && in_block == 0 { in_block = 1; print; next }
        in_block == 1 {
            if ($0 ~ /^- insert:/ || $0 ~ /^[[:space:]]*- id: /) { exit }
            print
        }
    ' "$patch_file"
}

# True when the legacy entry has exactly the known installer-generated shape.
# Every check is an anchored line match inside that same entry block.
legacy_block_valid() {
    local patch_file="$1"
    local block
    block="$(print_patch_block "$patch_file" "$LEGACY_ENTRY_ID")"
    [ -n "$block" ] || return 1
    printf '%s\n' "$block" | grep -qE "^[[:space:]]*name:[[:space:]]*'@dsh-local/dsh-cc-notify'[[:space:]]*$" || return 1
    printf '%s\n' "$block" | grep -qE "^[[:space:]]*scriptsDir:[[:space:]]*.*plugins/cc-notify-hooks/scripts[[:space:]]*$" || return 1
    printf '%s\n' "$block" | grep -qE "^[[:space:]]*stateDir:[[:space:]]*[^[:space:]]+[[:space:]]*$" || return 1
    return 0
}

# True when the migrated entry carries the canonical values.
migrated_block_valid() {
    local patch_file="$1"
    local block
    block="$(print_patch_block "$patch_file" "$PLUGIN_ENTRY_ID")"
    [ -n "$block" ] || return 1
    printf '%s\n' "$block" | grep -qE "^[[:space:]]*name:[[:space:]]*'@dsh-local/codex-push-hooks'[[:space:]]*$" || return 1
    printf '%s\n' "$block" | grep -qE "^[[:space:]]*scriptsDir:[[:space:]]*.*plugins/codex-push-hooks/scripts[[:space:]]*$" || return 1
    return 0
}

# Remove the legacy node_modules symlink only. Never touches real directories.
remove_legacy_link() {
    if [ -L "$LEGACY_LINK" ]; then
        rm -f "$LEGACY_LINK"
        echo -e "  ${CYAN}removed the legacy link $LEGACY_LINK${NC}"
    fi
}

# Rewrite a pre-rebrand legacy insert entry in place (id, scoped package
# name, and scripts directory). Only lines inside the legacy entry are
# touched. Callers must validate the block shape first.
migrate_legacy_patch_entry() {
    local patch_file="$1"
    local tmp_out="${patch_file}.tmp.$$"
    awk '
        in_legacy == 0 && /^[[:space:]]*- id: cc-notify-hooks[[:space:]]*$/ { in_legacy = 1; sub(/cc-notify-hooks[[:space:]]*$/, "codex-push-hooks") }
        in_legacy == 1 && /@dsh-local\/dsh-cc-notify/ { sub(/@dsh-local\/dsh-cc-notify/, "@dsh-local/codex-push-hooks") }
        in_legacy == 1 && /scriptsDir:.*plugins\/cc-notify-hooks\/scripts/ { sub(/plugins\/cc-notify-hooks\/scripts/, "plugins/codex-push-hooks/scripts") }
        { print }
        in_legacy == 1 && /^[[:space:]]*stateDir:/ { in_legacy = 0 }
    ' "$patch_file" > "$tmp_out" && mv "$tmp_out" "$patch_file"
}

# Preflight: inspect the patch state BEFORE creating, replacing, or removing
# either plugin symlink. Entry detection is anchored to real YAML list items,
# so a comment mentioning an id never counts as an entry.
CANONICAL_PRESENT=false
LEGACY_PRESENT=false
if [ -f "$PATCH_FILE" ]; then
    if grep -qE "^[[:space:]]*- id: ${PLUGIN_ENTRY_ID}[[:space:]]*$" "$PATCH_FILE"; then
        CANONICAL_PRESENT=true
    fi
    if grep -qE "^[[:space:]]*- id: ${LEGACY_ENTRY_ID}[[:space:]]*$" "$PATCH_FILE"; then
        LEGACY_PRESENT=true
    fi
fi

# Fatal patch states exit here with both plugin links unchanged.
if $CANONICAL_PRESENT && $LEGACY_PRESENT; then
    echo -e "  ${RED}✗${NC} $PATCH_FILE contains both a ${PLUGIN_ENTRY_ID} entry and a legacy ${LEGACY_ENTRY_ID} entry."
    echo -e "  ${YELLOW}Both integrations would fire at once. Neither entry was changed and no plugin link was touched.${NC}"
    echo -e "  ${YELLOW}Remove the legacy ${LEGACY_ENTRY_ID} entry manually, then re-run this installer.${NC}"
    exit 1
elif $LEGACY_PRESENT && ! legacy_block_valid "$PATCH_FILE"; then
    echo -e "  ${RED}✗${NC} the legacy ${LEGACY_ENTRY_ID} entry does not have the expected shape."
    echo -e "  ${YELLOW}$PATCH_FILE and both plugin links were left unchanged.${NC}"
    echo -e "  ${YELLOW}To recover manually:${NC}"
    echo -e "    1. Inspect the ${LEGACY_ENTRY_ID} entry in $PATCH_FILE."
    echo -e "    2. Delete that entry, or update it to id ${PLUGIN_ENTRY_ID} with name '@dsh-local/codex-push-hooks' and a codex-push-hooks scriptsDir."
    echo -e "    3. Re-run this installer."
    exit 1
fi

# Preflight passed: snapshot the canonical link state so a later failure can
# restore it, then create/update the canonical link.
# The managed link path must never clobber real user content: only an absent
# path or an existing symlink is safe. A broken symlink still counts as a
# symlink ([ -e ] is false for it, [ -L ] is true), so it passes through.
if [ -e "$PLUGIN_LINK" ] && [ ! -L "$PLUGIN_LINK" ]; then
    echo -e "  ${RED}✗${NC} $PLUGIN_LINK already exists and is not a symlink."
    echo -e "  ${YELLOW}Its contents were left untouched, as was $PATCH_FILE.${NC}"
    echo -e "  ${YELLOW}Move or remove that path manually, then re-run this installer.${NC}"
    exit 1
fi
LINK_WAS_PRESENT=false
LINK_WAS_LINK=false
LINK_TARGET=""
if [ -L "$PLUGIN_LINK" ]; then
    LINK_WAS_PRESENT=true
    LINK_WAS_LINK=true
    LINK_TARGET="$(readlink "$PLUGIN_LINK")"
elif [ -e "$PLUGIN_LINK" ]; then
    LINK_WAS_PRESENT=true
fi
mkdir -p "$NODE_MODULES_DIR"
ln -sfn "$PLUGIN_PKG_DIR" "$PLUGIN_LINK"
echo -e "  ${GREEN}✓${NC} $PLUGIN_LINK -> $PLUGIN_PKG_DIR"

restore_link_state() {
    # Best-effort rollback of the canonical link; never deletes real content.
    if $LINK_WAS_LINK; then
        ln -sfn "$LINK_TARGET" "$PLUGIN_LINK"
    elif ! $LINK_WAS_PRESENT && [ -L "$PLUGIN_LINK" ]; then
        rm -f "$PLUGIN_LINK"
    fi
}

# ============================================================
#  [4/5] Write ~/.dsh/cordis.patch.yml
# ============================================================
echo -e "${YELLOW}[4/5]${NC} writing the dsh plugin configuration..."

# Patch block, entry helpers, and migration live in the step [3/5] preflight above.

# Preflight already ruled out duplicate entries and invalid legacy shapes,
# and no patch write happened since, so these flags are still accurate.
if $CANONICAL_PRESENT; then
    echo -e "  ${YELLOW}⚠${NC} $PATCH_FILE already has a ${PLUGIN_ENTRY_ID} entry; skipping the write"
    # No legacy entry references the old link, so the stale link can go.
    remove_legacy_link
elif $LEGACY_PRESENT; then
    BACKUP="${PATCH_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$PATCH_FILE" "$BACKUP"
    echo "  backed up the original configuration to: $BACKUP"
    migrate_legacy_patch_entry "$PATCH_FILE"
    if [ "$(grep -cE "^[[:space:]]*- id: ${PLUGIN_ENTRY_ID}[[:space:]]*$" "$PATCH_FILE")" = "1" ] \
        && ! grep -qE "^[[:space:]]*- id: ${LEGACY_ENTRY_ID}[[:space:]]*$" "$PATCH_FILE" \
        && migrated_block_valid "$PATCH_FILE"; then
        echo -e "  ${GREEN}✓${NC} migrated the legacy ${LEGACY_ENTRY_ID} entry to ${PLUGIN_ENTRY_ID} (no duplicate registration)"
        # The migrated entry no longer references the old link.
        remove_legacy_link
    else
        cp "$BACKUP" "$PATCH_FILE"
        restore_link_state
        echo -e "  ${RED}✗${NC} post-migration verification failed; restored $PATCH_FILE from the backup and rolled back the canonical link."
        echo -e "  ${YELLOW}Reconcile the entries manually, then re-run this installer.${NC}"
        exit 1
    fi
else
    if [ -f "$PATCH_FILE" ] && [ -s "$PATCH_FILE" ]; then
        BACKUP="${PATCH_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$PATCH_FILE" "$BACKUP"
        echo "  backed up the original configuration to: $BACKUP"
        printf '%s\n' "$PATCH_BLOCK" >> "$PATCH_FILE"
    else
        mkdir -p "$DSH_HOME_DIR"
        printf '%s\n' "$PATCH_BLOCK" > "$PATCH_FILE"
    fi
    echo -e "  ${GREEN}✓${NC} wrote the ${PLUGIN_ENTRY_ID} entry to $PATCH_FILE"
    # Fresh canonical entry; no legacy entry references the old link.
    remove_legacy_link
fi
mkdir -p "$STATE_DIR"

# ============================================================
#  [5/5] Verification (prints the entry from the composition tree when dsh is available)
# ============================================================
echo -e "${YELLOW}[5/5]${NC} verifying..."
if command -v dsh &>/dev/null; then
    if dsh web --dump-config 2>/dev/null | grep -q "id: ${PLUGIN_ENTRY_ID}"; then
        echo -e "  ${GREEN}✓${NC} the dsh composition tree already contains ${PLUGIN_ENTRY_ID}"
    else
        echo -e "  ${YELLOW}⚠${NC} the dsh composition tree does not contain ${PLUGIN_ENTRY_ID} yet (a running dsh hot-loads this file, otherwise it applies on the next start)"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} dsh CLI not detected; skipping verification (re-run this script after installing dsh)"
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
echo "  Next steps:"
echo "  1. Test: bash $REPO_ROOT/test_notify.sh"
echo "  2. dsh hot-loads $PATCH_FILE; running sessions take effect immediately"
echo "  3. Debug: tail -f /tmp/claude-hooks-debug.log"
echo ""
echo "  Event mapping (dsh interception point → notification):"
echo "    approval/request    → push while waiting for approval (approval needed 🔔)"
echo "    agent/turn-stopping → push when a turn ends (task complete ✅)"
echo "    agent/pre-step      → cancel queued pushes once the user responds"
echo "    tools/pre-execute   → push for ask_user_question (reply needed 🔔)"
echo ""
echo "  Uninstall: delete the codex-push-hooks entry from $PATCH_FILE and remove $PLUGIN_LINK"
echo "  Change the configuration: edit $CONFIG_FILE"
echo "========================================="
