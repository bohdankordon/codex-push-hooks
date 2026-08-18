#!/usr/bin/env bash
#
# cc-notify-hooks 独立安装脚本（Reasonix 分支）
# 配置写入 ~/.reasonix/cc-notify-hooks/notify.json，
# 插件以 --link 方式注册到 Reasonix（reasonix plugin install）。
#
# 既可被 install.sh 路由调用，也可独立运行：
#   bash install/reasonix.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="${REPO_ROOT}/plugins/cc-notify-hooks"
REASONIX_HOME_DIR="${REASONIX_HOME:-${HOME}/.reasonix}"
INSTALL_DIR="${REASONIX_HOME_DIR}/cc-notify-hooks"
CONFIG_FILE="${INSTALL_DIR}/notify.json"
STATE_DIR="${HOME}/.claude/hooks/state"  # 与其他 agent 共用 state 目录

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MACOS=true

echo "========================================="
echo "  cc-notify-hooks - Reasonix 独立安装"
echo "  平台: $(uname -s) $(uname -m)"
echo "========================================="
echo ""

# ============================================================
#  [1/4] 检查依赖
# ============================================================
echo -e "${YELLOW}[1/4]${NC} 检查依赖..."
MISSING_DEP=0
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "  ${RED}✗${NC} $cmd 未安装"
        MISSING_DEP=1
    else
        echo -e "  ${GREEN}✓${NC} $cmd"
    fi
done
if [ "$MISSING_DEP" -eq 1 ]; then
    echo ""
    echo "  请先安装缺失的依赖："
    if $IS_MACOS; then
        echo "  macOS:         brew install jq curl"
    else
        echo "  Debian/Ubuntu: sudo apt install -y jq curl"
        echo "  CentOS/RHEL:   sudo yum install -y jq curl"
    fi
    exit 1
fi

if ! command -v reasonix &>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} 未检测到 reasonix CLI（继续安装，请稍后再装 Reasonix）"
fi

# ============================================================
#  [2/4] 交互式配置
# ============================================================
echo -e "${YELLOW}[2/4]${NC} 配置推送渠道..."
echo ""

# Channel 定义：name|display_name|default_delay|credential_fields
CHANNEL_DEFS=(
    "macos|macOS 系统通知|3|"
    "bark|Bark (iOS/macOS/Android)|15|key:Bark Key;server:Bark Server [https://api.day.app]"
    "telegram|Telegram Bot|5|bot_token:Bot Token;chat_id:Chat ID"
    "pushover|Pushover|15|app_token:App Token;user_key:User Key"
    "ntfy|ntfy (开源推送)|15|topic:Topic;server:Server [https://ntfy.sh]"
    "gotify|Gotify (自建推送)|15|server:Server URL;app_token:App Token"
    "wechat|企业微信|300|webhook:Webhook URL"
    "feishu|飞书|300|webhook:Webhook URL"
    "dingtalk|钉钉|300|webhook:Webhook URL"
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

# 复用已有配置（Claude / Codex），避免重复填写凭证
if [ ! -f "$CONFIG_FILE" ]; then
    for existing in \
        "${HOME}/.claude/hooks/notify.json" \
        "${CODEX_HOME:-${HOME}/.codex}/cc-notify-hooks/notify.json"; do
        if [ -f "$existing" ]; then
            echo -e "  ${CYAN}检测到已有配置，可直接复用${NC}"
            printf "  复用 $existing ? [Y/n]: "
            read -r reuse
            if [[ ! "$reuse" =~ ^[Nn] ]]; then
                mkdir -p "$INSTALL_DIR"
                cp "$existing" "$CONFIG_FILE"
                echo -e "  ${GREEN}✓${NC} 已复用配置"
                echo ""
            fi
            break
        fi
    done
fi

if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${CYAN}检测到已有配置 ($CONFIG_FILE)${NC}"
    echo ""
fi

# 列出 channel 让用户选择
echo "  可用的通知渠道："
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
    printf "  %s [%b] %2d. %-30s (默认延迟 %ss)\n" "" "$mark" "$idx" "$display" "$delay"
    idx=$((idx + 1))
done
echo ""
echo -e "  ${CYAN}输入编号启用渠道（逗号分隔，如 1,2,7），直接回车保持当前配置${NC}"

printf "  选择: "
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

# 收集凭证
declare -A CHANNEL_CONFIGS=()

for def in "${CHANNEL_DEFS[@]}"; do
    IFS='|' read -r name display delay fields <<< "$def"

    if [ "${ENABLED_CHANNELS[$name]:-}" != "1" ]; then
        continue
    fi
    if [ -z "$fields" ]; then
        continue
    fi

    echo -e "  ${CYAN}配置 ${display}:${NC}"

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
            hint="必填"
        fi

        printf "    %s [%s]: " "$fdesc" "$hint"
        read -r input
        CHANNEL_CONFIGS["${name}.${fkey}"]="${input:-$current}"
    done
    echo ""
done

# 构建配置 JSON
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
echo -e "  ${GREEN}✓${NC} 配置已写入 $CONFIG_FILE"

# ============================================================
#  [3/4] 注册插件到 Reasonix
# ============================================================
echo -e "${YELLOW}[3/4]${NC} 注册插件到 Reasonix（--link 指向本仓库）..."
mkdir -p "$STATE_DIR"

reasonix plugin install "$PLUGIN_DIR" --link --replace --yes >/dev/null

HOOK_COUNT=$(reasonix hook list --json 2>/dev/null | jq -r '.hooks | length' 2>/dev/null || echo "?")
echo -e "  ${GREEN}✓${NC} 插件已注册，Reasonix 加载了 ${HOOK_COUNT} 个 hook"

# ============================================================
#  [4/4] 总结输出
# ============================================================
echo ""
ENABLED_COUNT=0
for name in "${!ENABLED_CHANNELS[@]}"; do
    [ "${ENABLED_CHANNELS[$name]}" = "1" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
done

if [ "$ENABLED_COUNT" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} 未启用任何推送渠道"
else
    echo "  已启用的渠道："
    for def in "${CHANNEL_DEFS[@]}"; do
        IFS='|' read -r name display delay _ <<< "$def"
        if [ "${ENABLED_CHANNELS[$name]:-}" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ${display} (延迟 ${delay}s)"
        fi
    done
fi

echo ""
echo "========================================="
echo -e "  ${GREEN}✅ 安装完成！${NC}"
echo ""
echo "  下一步:"
echo "  1. 测试: bash $REPO_ROOT/test_notify.sh"
echo "  2. 重启 Reasonix 会话使 hooks 生效（/new 不会重新加载）"
echo "  3. 调试: tail -f /tmp/claude-hooks-debug.log"
echo ""
echo "  事件映射:"
echo "    Notification       → 等待工具审批时推送（需要确认 🔔）"
echo "    Stop               → 一轮对话结束推送（任务完成 ✅）"
echo "    UserPromptSubmit   → 用户响应后取消排队推送"
echo "    PreToolUse(ask)    → 提问时推送（需要回复 🔔），其他工具清理 pending"
echo ""
echo "  管理: reasonix plugin show cc-notify-hooks"
echo "  卸载: reasonix plugin remove cc-notify-hooks --yes"
echo "  修改配置: 编辑 $CONFIG_FILE"
echo "========================================="
