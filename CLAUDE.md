# cc-notify-hooks

Claude Code、Codex CLI、Reasonix 与 dsh（DeepSeek Harness）的分级推送通知系统。通过 hook/拦截点触发多渠道通知，用户响应后自动取消排队中的推送。

## 技术栈

- **语言**: Bash（核心脚本）+ JavaScript（dsh 宿主插件，零依赖）
- **依赖**: `jq`（JSON 解析）、`curl`（HTTP 请求）、`osascript`（macOS 通知）
- **集成**: Claude Code / Codex CLI / Reasonix 的 hooks 插件机制 + dsh 的 cordis 拦截点

## 项目结构

```
plugins/cc-notify-hooks/    # 真实插件根目录（根目录的 scripts/hooks/config 是软链）
├── scripts/notify.sh       # 主调度器：事件过滤、延迟排队、渠道分发（兼容 4 个 agent 字段）
├── scripts/clear_pending.sh# 清除待发通知（用户交互时触发）
├── scripts/pre_tool_use.sh # 提问工具 dispatcher（request_user_input / ask / AskUserQuestion）
├── scripts/channels/*.sh   # 11 个渠道实现
├── hooks/hooks.json        # Claude Code hook 事件定义
├── hooks/codex-hooks.json  # Codex CLI hook 事件定义
├── reasonix-plugin.json    # Reasonix 原生插件清单（v2，payloadFormat=claude）
├── dsh-plugin/             # dsh 宿主插件（cordis，订阅 5 个拦截点）
├── .claude-plugin/         # Claude Code 插件清单
├── .codex-plugin/          # Codex CLI 插件清单
├── config/notify.example.json
└── skills/config/SKILL.md  # 交互式配置 skill（Claude Code 专属）
install.sh                  # 独立安装入口（路由）
install/{claude,codex,reasonix,dsh}.sh
test_notify.sh              # 渠道连通性 + 模板/agent 识别测试
```

## 常用命令

```bash
# 安装
bash install.sh                  # 交互式选择 Claude Code / Codex / Reasonix / dsh
bash install.sh claude|codex|reasonix|dsh

# 测试
bash test_notify.sh              # 测试所有已启用渠道
bash test_notify.sh bark         # 测试单个渠道
bash test_notify.sh hook         # 模拟 Claude Code hook 流程
bash test_notify.sh codex        # 模拟 Codex CLI PermissionRequest 事件
bash test_notify.sh agents       # 验证 Reasonix / dsh agent 识别
node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs  # dsh 插件单元测试

# 插件模式运行
claude --plugin-dir ./cc-notify-hooks
reasonix plugin install ./plugins/cc-notify-hooks --link --yes
```

## 核心机制

- **分级延迟**: 短通知（秒级：macOS/Bark/Telegram）→ 长通知（分钟级：微信/飞书/钉钉/Slack）
- **Pending 取消**: 发送前创建标记文件，用户响应时清除，后台进程检查标记决定是否发送
- **速率限制**: 同类事件默认 10 秒内不重复推送
- **事件过滤**: 跳过子 agent、Stop 循环保护、/exit 静默

## 配置

配置文件查找顺序（`scripts/notify.sh` 实现）:
1. `${CC_NOTIFY_CONFIG}`（手动覆盖）
2. `${PLUGIN_DATA}/notify.json`（Codex 插件模式）、`${CLAUDE_PLUGIN_DATA}/notify.json`（Claude 插件模式）
3. `~/.codex/cc-notify-hooks/notify.json`（Codex 独立模式）
4. `~/.reasonix/cc-notify-hooks/notify.json`（Reasonix，`REASONIX_HOME` 可覆盖）
5. `~/.dsh/cc-notify-hooks/notify.json`（dsh，`DSH_HOME` 可覆盖）
6. `~/.claude/hooks/notify.json`（Claude 独立模式）

```json
{
  "channels": {
    "channel_name": {
      "enabled": true,
      "delay": 3,
      "events": ["notification", "stop"]
    }
  },
  "rate_limit": 10
}
```

## 开发注意

- 所有渠道脚本遵循相同接口：接收 `$1`=标题 `$2`=内容，从环境变量/配置读取凭据
- 渠道发送用 `|| true` 包裹，单个失败不影响其他渠道
- 无配置文件时 macOS 用户自动降级为系统通知

## 开发规范

### 插件开发

**Claude Code**:
- 清单 `.claude-plugin/plugin.json`，hook 配置 `hooks/hooks.json`
- 路径引用 `${CLAUDE_PLUGIN_ROOT}`（插件根）和 `${CLAUDE_PLUGIN_DATA}`（持久数据）
- 插件变更后 `claude plugin validate .` 验证，`claude --plugin-dir .` 本地测试
- skill 交互注意 AskUserQuestion 限制：每个问题 2-4 个选项

**Codex CLI**:
- 清单 `.codex-plugin/plugin.json`，hook 配置 `hooks/codex-hooks.json`
- Codex hook 命令以会话 `cwd` 执行，不能用 `./scripts/...`；插件模式需从 `~/.codex/plugins/cache/*/cc-notify-hooks/*/` 定位脚本
- Marketplace `.agents/plugins/marketplace.json`，policy 必填 installation/authentication/category
- 启用 hooks 需要 `~/.codex/config.toml` 添加 `[features]\ncodex_hooks = true`
- 字段差异：Codex `prompt` ↔ Claude `message`（已在脚本里 fallback），Codex 无 Notification 事件（用 PermissionRequest 替代）

**Reasonix**:
- 清单 `reasonix-plugin.json`（`reasonix.io/plugin/v2`，严格解析：不允许 author/license/keywords 等未知字段）
- hook 用 exec form（`command: "bash"` + `args`）+ `payloadFormat: "claude"`——exec+claude 组合豁免插件根路径拼接，脚本才能收到 Claude 形状 stdin（`hook_event_name`/`session_id`/`message`/`notification_type`…）
- Reasonix 支持 11 个事件：PreToolUse/PostToolUse/UserPromptSubmit/Stop/Notification/SessionStart/SessionEnd/SubagentStop/PreCompact/PostLLMCall/PermissionRequest
- 审批等待触发 `Notification`（`notification_type=permission_prompt`），提问工具叫 `ask`（Claude 名 `AskUserQuestion`，输入 schema 与 notify.sh 解析兼容）
- 安装/验证：`reasonix plugin install <dir> --dry-run`（看 compatibility）→ `--link --yes` → `reasonix hook list --json` / `reasonix doctor capabilities --json`
- 原生 hook 的 stdin 用 `event`/`sessionId`/`lastAssistantText` 字段（脚本已兜底兼容）；插件导入格式才带 `hook_event_name`
- hooks 在会话构建时加载：改配置后要重启会话，`/new` 不会重载

**dsh（DeepSeek Harness）**:
- 宿主插件 `dsh-plugin/`（cordis，`export const name` + `export function apply(ctx, config)`，零依赖仅用 node 内置）
- 订阅拦截点：`approval/request`（瀑布，观察后必须 `next()` 代理）、`agent/turn-stopping`（serial，payload 带 `agent` 注入）、`agent/pre-step`、`tools/pre-execute`（`exec.name/arguments/callId/agent`）、`tools/post-execute`、`session/event`（跟踪 `assistant/message` 摘要）
- 提问工具叫 `ask_user_question`，插件转发时改写为 `request_user_input` 复用 pre_tool_use.sh 的解析
- 安装方式（与 dsh-feishu 相同）：软链到 `~/node_modules/@dsh-local/dsh-cc-notify` + `~/.dsh/cordis.patch.yml` 追加 insert（`name: '@dsh-local/dsh-cc-notify'`）
- dsh 热加载 home 级 `~/.dsh/cordis.patch.yml`（`watchUserPatches`），运行中会话无需重启；`dsh web --dump-config` 验证组合树
- 插件测试：`node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs`（stub 脚本捕获 spawn，mock ctx 驱动事件）

**多 agent 共用**:
- 渠道脚本接口：`$1`=标题 `$2`=内容，从环境变量/配置读取凭据
- 渠道发送 `|| true` 包裹，单个失败不影响其他渠道
- Agent 名识别（notify.sh）：`CC_NOTIFY_AGENT` 覆盖 → `REASONIX_PLUGIN_ROOT`（Reasonix）→ `DSH_CC_NOTIFY`（dsh）→ Notification/`.claude` 路径（Claude Code）→ 默认 Codex
- state 目录默认共用 `~/.claude/hooks/state`，按 session 隔离

### 版本与发布

- 版本号遵循语义化版本（MAJOR.MINOR.PATCH）
- 更新版本号前必须向用户确认目标版本号，不得自行决定
- 六份清单同步更新版本号：`.claude-plugin/plugin.json`、`.claude-plugin/marketplace.json`、`.codex-plugin/plugin.json`、`.agents/plugins/marketplace.json`、`plugins/cc-notify-hooks/reasonix-plugin.json`、`plugins/cc-notify-hooks/dsh-plugin/package.json`
- 功能变更须同步更新 README 与 `docs/index.html`（GitHub Pages）
- 发布流程：commit → push → `gh release create vX.Y.Z`

### README 维护

- 新增功能必须更新 README 的对应章节（配置、文件结构等）
- 用户不一定需要重启 Claude Code，`/reload-plugins` 即可刷新插件

## 参考文档

- [Claude Code 插件开发指南](https://code.claude.com/docs/en/plugins.md)
- [Claude Code 插件参考](https://code.claude.com/docs/en/plugins-reference.md)
- [Codex Hooks 文档](https://developers.openai.com/codex/hooks)
- [Codex 配置参考](https://developers.openai.com/codex/config-reference)
- [Reasonix 插件包文档](https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/docs/PLUGIN_PACKAGES.md)
- [Reasonix Desktop Hooks 文档](https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/docs/DESKTOP_HOOKS.zh-CN.md)
- dsh 拦截点 Agent Note：`~/.dsh/source/current/.agents/notes/implemented/feature/2026-06-30-interception-extension-points.md`
- dsh 审批 seam Agent Note：`~/.dsh/source/current/.agents/notes/implemented/feature/2026-07-06-approval-seam.md`
