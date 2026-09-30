#!/usr/bin/env bash
#
# codex-push-hooks standalone install entry point (router)
#
# Usage:
#   bash install.sh           # choose a target interactively
#   bash install.sh claude    # install the Claude Code branch directly
#   bash install.sh codex     # install the Codex CLI branch directly
#   bash install.sh reasonix  # install the Reasonix branch directly
#   bash install.sh dsh       # install the dsh (DeepSeek Harness) branch directly
#
# Or bypass the router and call a branch script directly:
#   bash install/claude.sh
#   bash install/codex.sh
#   bash install/reasonix.sh
#   bash install/dsh.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
#  Parse arguments / interactive selection
# ============================================================
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "========================================="
    echo "  codex-push-hooks - standalone install"
    echo "========================================="
    echo ""
    echo "  Choose which tool to install into:"
    echo ""
    echo "    1) Claude Code  (~/.claude/)"
    echo "    2) Codex CLI    (~/.codex/)"
    echo "    3) Reasonix     (~/.reasonix/)"
    echo "    4) dsh          (~/.dsh/, DeepSeek Harness)"
    echo ""
    printf "  Choose [1/2/3/4]: "
    read -r choice

    case "$choice" in
        1) TARGET="claude" ;;
        2) TARGET="codex" ;;
        3) TARGET="reasonix" ;;
        4) TARGET="dsh" ;;
        *) echo -e "  ${YELLOW}Invalid choice, exiting${NC}" ; exit 1 ;;
    esac
    echo ""
fi

# ============================================================
#  Dispatch to the branch script
# ============================================================
case "$TARGET" in
    claude|claude-code|cc)
        echo -e "${CYAN}→ entering the Claude Code branch${NC}"
        echo ""
        exec bash "$REPO_ROOT/install/claude.sh"
        ;;
    codex)
        echo -e "${CYAN}→ entering the Codex CLI branch${NC}"
        echo ""
        exec bash "$REPO_ROOT/install/codex.sh"
        ;;
    reasonix)
        echo -e "${CYAN}→ entering the Reasonix branch${NC}"
        echo ""
        exec bash "$REPO_ROOT/install/reasonix.sh"
        ;;
    dsh|deepseek|harness)
        echo -e "${CYAN}→ entering the dsh branch${NC}"
        echo ""
        exec bash "$REPO_ROOT/install/dsh.sh"
        ;;
    *)
        echo "  Unknown target: $TARGET"
        echo "  Supported targets: claude, codex, reasonix, dsh"
        exit 1
        ;;
esac
