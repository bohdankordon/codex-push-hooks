# cc-notify-hooks

**Claude Code**、**Codex CLI**、**Reasonix** 与 **dsh（DeepSeek Harness）** 的分级推送通知系统。支持 **11 个通知渠道**，可作为插件或独立脚本使用，各 agent 共享同一份配置。

## 为什么需要分级通知？

Claude Code、Codex、Reasonix 和 dsh 的任务常常需要几秒到几十分钟不等。你不会一直盯着终端，但又需要在合适的时候回来操作。

**cc-notify-hooks 将通知分为两级**：

**短通知（秒级）** — 你可能只是切到了浏览器或聊天窗口。系统通知、手机推送这类**即时触达**的渠道会在几秒内提醒你"Claude 需要你"。如果你看到通知并回来操作了，后续推送自动取消——不会再打扰你。

**长通知（分钟级）** — 你可能离开了电脑、在开会、甚至不在手机旁。企业微信群、飞书群、Slack 频道这类**团队/异步渠道**会在几分钟后兜底通知。即使你错过了短通知，最终也能从工作沟通工具里看到任务状态。

**核心机制**：每次推送前检查用户是否已响应（pending 文件是否还在）。用户一旦回来操作，当前 Session 排队中的推送自动作废，其他并行 Session 不受影响。短通知解决了问题，长通知就不会再发。

## 支持的渠道

### 短通知渠道（即时触达）

适合切屏、短暂离开的场景。

| 渠道 | 默认延迟 | 说明 |
|------|---------|------|
| **macOS** | 3s | 零配置，系统原生通知 |
| **Telegram** | 5s | Bot 消息，手机即时推送 |
| **Bark** | 15s | iOS / macOS / Android 推送 |
| **Pushover** | 15s | 跨平台推送服务 |
| **ntfy** | 15s | 开源推送，支持自建 |
| **Gotify** | 15s | 自建推送服务 |

### 长通知渠道（异步兜底）

适合离开电脑、开会、或需要团队可见的场景。

| 渠道 | 默认延迟 | 说明 |
|------|---------|------|
| **企业微信** | 5min | 群机器人 Webhook |
| **飞书** | 5min | 群机器人 Webhook |
| **钉钉** | 5min | 群机器人 Webhook |
| **Slack** | 5min | Incoming Webhook |
| **Discord** | 5min | Channel Webhook |

每个渠道的延迟可独立调整。只启用你需要的渠道，其余自动跳过。

## 工作原理

```
Claude Code / Codex CLI 事件
    │
    ├─ Codex request_user_input → PreToolUse dispatcher → 等待输入通知
    │                                      └─ PostToolUse → 定向取消
    ▼
notify.sh ── 清除当前 Session 的旧 pending → 创建新 pending
    │
    │  ┌── 短通知 ──────────────────────────────────┐
    ├─ │ 3s  → pending 还在？ → macOS 系统通知      │
    ├─ │ 5s  → pending 还在？ → Telegram             │
    ├─ │ 15s → pending 还在？ → Bark / ntfy / ...    │
    │  └────────────────────────────────────────────┘
    │  ┌── 长通知 ──────────────────────────────────┐
    └─ │ 5m  → pending 还在？ → 企微 / 飞书 / Slack │
       └────────────────────────────────────────────┘

用户回来操作（发消息 / 回答问题 / 点权限按钮）
    └─→ clear_pending.sh → 清除当前 Session pending → 后续推送全部取消
         （短通知解决了，长通知就不发了）
```

## 安装

### 依赖

- **jq** — 解析 JSON（`brew install jq` / `apt install jq`）
- **curl** — 发送推送（通常已预装）

### 方式一：Claude Code Marketplace（推荐 Claude 用户）

在 Claude Code 中执行：

```
/plugin marketplace add MarioZZJ/cc-notify-hooks
/plugin install cc-notify-hooks@cc-notify-hooks
```

安装后运行 `/reload-plugins` 刷新，然后执行 `/cc-notify-hooks:config` 启动交互式配置向导（见下方[配置](#配置)章节）。

### 方式二：Codex CLI Marketplace（推荐 Codex 用户）

仓库根目录的 `.agents/plugins/marketplace.json` 是 Codex marketplace，实际插件目录是 `plugins/cc-notify-hooks/`。在终端执行：

```bash
codex plugin marketplace add MarioZZJ/cc-notify-hooks --ref v2.4.0
codex plugin add cc-notify-hooks@cc-notify-hooks
```

启用 hooks（必需，Codex 默认关闭）：在 `~/.codex/config.toml` 添加：

```toml
[features]
codex_hooks = true
```

之后重启 Codex，或在新会话中使用插件。安装或升级后，打开 `/hooks` 审阅并信任新增或变更的 hook 定义，否则 Codex 会跳过它们。

注意：Codex 的 hook 命令运行目录是当前会话 `cwd`，不是插件根目录。`.codex-plugin/plugin.json` 只负责把 `hooks/codex-hooks.json` 作为生命周期配置打包进去；hook 命令不能写成 `./scripts/...`。本插件使用 Codex 提供的 `PLUGIN_ROOT` 定位脚本、使用 `PLUGIN_DATA` 保存插件配置和状态，因此兼容自定义 `CODEX_HOME`，不依赖固定的插件缓存路径。

### 方式三：本地插件模式

```bash
git clone https://github.com/MarioZZJ/cc-notify-hooks.git

# Claude Code
claude --plugin-dir ./cc-notify-hooks/plugins/cc-notify-hooks

# Codex CLI: 见上文 Codex Marketplace 方式
```

### 方式四：独立安装（无需插件）

```bash
git clone https://github.com/MarioZZJ/cc-notify-hooks.git
cd cc-notify-hooks
bash install.sh                  # 交互式选择 Claude Code / Codex / Reasonix / dsh
bash install.sh claude           # 直接装到 Claude Code
bash install.sh codex            # 直接装到 Codex CLI
bash install.sh reasonix         # 直接装到 Reasonix
bash install.sh dsh              # 直接装到 dsh (DeepSeek Harness)
```

安装脚本会交互式引导你选择渠道、输入凭证，自动生成配置：

- **Claude 分支**：写 `~/.claude/hooks/notify.json`，合并 hooks 到 `~/.claude/settings.json`
- **Codex 分支**：写 `~/.codex/cc-notify-hooks/notify.json`，合并 hooks 到 `~/.codex/hooks.json`，提示你启用 `codex_hooks`
- **Reasonix 分支**：写 `~/.reasonix/cc-notify-hooks/notify.json`，以 `reasonix plugin install --link` 注册本仓库插件（`reasonix-plugin.json` 声明 5 个 hook）
- **dsh 分支**：写 `~/.dsh/cc-notify-hooks/notify.json`，软链插件包到 `~/node_modules/@dsh-local/dsh-cc-notify`，并在 `~/.dsh/cordis.patch.yml` 追加 insert 条目（dsh 热加载，无需重启）

**Claude 安装后运行 `/reload-plugins` 刷新；Codex 安装后重启 Codex 进程；Reasonix 安装后重启会话；dsh 安装后立即生效。**

### 方式五：Reasonix 插件包（推荐 Reasonix 用户）

Reasonix 原生支持本仓库的 `reasonix-plugin.json`（`reasonix.io/plugin/v2`），可从 GitHub 仓库或本地目录安装：

```bash
# 从 GitHub（仓库根是兼容的 Claude marketplace，会安装 plugins/cc-notify-hooks）
reasonix plugin install git:github.com/MarioZZJ/cc-notify-hooks --yes

# 或本地 clone 后链接安装（开发模式，仓库更新即时生效）
git clone https://github.com/MarioZZJ/cc-notify-hooks.git
reasonix plugin install ./cc-notify-hooks/plugins/cc-notify-hooks --link --yes
```

安装后：

```bash
reasonix plugin show cc-notify-hooks   # 查看 5 个 hook
reasonix hook list --json              # 确认 hook 已加载
```

插件 hook 使用 `payloadFormat: "claude"`，脚本收到的 stdin 与 Claude Code 字段一致（`hook_event_name`/`session_id`/`message`…），共享同一份 `notify.sh`。配置文件放在 `~/.reasonix/cc-notify-hooks/notify.json`（也可复用 `~/.claude/hooks/notify.json` 或 `~/.codex/cc-notify-hooks/notify.json`，脚本按顺序查找）。

### 方式六：dsh 插件（DeepSeek Harness）

dsh 没有外部 shell hook，本仓库内置了一个零依赖的宿主插件 `dsh-cc-notify`（`plugins/cc-notify-hooks/dsh-plugin/`），直接订阅 dsh 的拦截点（`approval/request`、`agent/turn-stopping`、`agent/pre-step`、`tools/pre-execute`、`tools/post-execute`），并调用同一套 `scripts/`。

推荐直接使用独立安装分支：

```bash
cd cc-notify-hooks && bash install/dsh.sh
```

它做三件事：软链插件包到 `~/node_modules/@dsh-local/dsh-cc-notify`、写 `~/.dsh/cc-notify-hooks/notify.json`、在 `~/.dsh/cordis.patch.yml` 追加：

```yaml
- insert:
    - id: cc-notify-hooks
      name: '@dsh-local/dsh-cc-notify'
      config:
        scriptsDir: /path/to/cc-notify-hooks/plugins/cc-notify-hooks/scripts
        stateDir: /home/you/.claude/hooks/state
```

dsh 会热加载 `~/.dsh/cordis.patch.yml`，正在运行的会话即刻生效（`dsh web --dump-config` 可验证条目已进入组合树）。插件单元测试：

```bash
node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs
```

### 验证

```bash
bash test_notify.sh              # 测试所有已启用渠道
bash test_notify.sh bark         # 测试单个渠道
bash test_notify.sh list         # 查看已启用渠道及延迟
bash test_notify.sh hook         # 模拟 Claude Code hook 流程
bash test_notify.sh codex        # 模拟 Codex CLI PermissionRequest 事件
bash test_notify.sh codex-plugin-hooks  # 验证 Codex 插件 hook 路径解析
bash test_notify.sh user-input   # 验证 request_user_input dispatcher 与模板
bash test_notify.sh state        # 验证多 Session 状态隔离与精确去重
bash test_notify.sh render       # 验证通知内容模板
bash test_notify.sh agents       # 验证 Reasonix / dsh 的 agent 识别与事件字段
node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs  # dsh 插件单元测试
```

## 配置

### 方式一：交互式配置（推荐）

在 Claude Code 中运行：

```
/cc-notify-hooks:config
```

配置向导会引导你：
1. 选择要启用的**短通知渠道**（macOS、Telegram、Bark 等）
2. 选择要启用的**长通知渠道**（企业微信、飞书、Slack 等）
3. 逐个输入渠道凭证，附带获取指引
4. 调整延迟时间
5. 测试渠道连通性

已有配置的渠道会标注当前状态，支持随时修改。

### 方式二：手动编辑配置文件

创建配置文件 `~/.claude/hooks/notify.json`，可从模板复制后编辑：

```bash
# marketplace 安装：从项目仓库获取模板
curl -sL https://raw.githubusercontent.com/MarioZZJ/cc-notify-hooks/main/plugins/cc-notify-hooks/config/notify.example.json \
  -o ~/.claude/hooks/notify.json

# 本地 clone：直接复制
cp config/notify.example.json ~/.claude/hooks/notify.json
```

然后编辑配置文件，将你需要的渠道设为 `"enabled": true` 并填入凭证：

```json
{
  "channels": {
    "macos": { "enabled": true, "delay": 3, "events": ["notification"] },
    "bark":  { "enabled": true, "delay": 15, "key": "your-key", "server": "https://api.day.app" },
    "telegram": { "enabled": true, "delay": 5, "bot_token": "123:ABC", "chat_id": "123456" }
  },
  "rate_limit": 10
}
```

完整配置模板见 [`config/notify.example.json`](config/notify.example.json)。

### 字段说明

| 字段 | 说明 |
|------|------|
| `enabled` | 是否启用该渠道 |
| `delay` | 推送延迟（秒），可自由调整 |
| `events` | 可选，响应的事件类型，默认 `["notification", "stop"]`。Codex 等待输入在内部标记为 `user_input`，渠道过滤仍按 `notification`，旧配置无需修改 |
| `format` | 可选，长通知渠道的展示格式。飞书默认 `card`，企业微信/钉钉/Slack 默认 `markdown`，Discord 默认 `embed` |
| 其他字段 | 各渠道的凭证（key、webhook、token 等） |

### 各渠道凭证

<details>
<summary><b>Bark</b></summary>

1. 安装 [Bark App](https://github.com/Finb/Bark)
2. 首页推送 URL `https://api.day.app/xxxxxxxx`，`xxxxxxxx` 即为 `key`
3. 自建服务器设置 `server` 字段
</details>

<details>
<summary><b>Telegram</b></summary>

1. 在 Telegram 中找 [@BotFather](https://t.me/BotFather)，创建 Bot，获取 `bot_token`
2. 向你的 Bot 发一条消息
3. 访问 `https://api.telegram.org/bot<TOKEN>/getUpdates` 获取 `chat_id`
</details>

<details>
<summary><b>Pushover</b></summary>

1. 注册 [pushover.net](https://pushover.net)，获取 `user_key`
2. 创建 Application，获取 `app_token`
</details>

<details>
<summary><b>ntfy</b></summary>

1. 安装 [ntfy App](https://ntfy.sh)，订阅一个 topic
2. 配置 `topic` 字段，自建服务器设置 `server`
</details>

<details>
<summary><b>Gotify</b></summary>

1. 自建 [Gotify](https://gotify.net) 服务
2. 创建 Application，获取 `app_token`
3. 配置 `server` 和 `app_token`
</details>

<details>
<summary><b>企业微信</b></summary>

1. 群聊 → 右上角「⋯」→ 群机器人 → 添加 → 新创建
2. 复制 Webhook 地址到 `webhook` 字段
</details>

<details>
<summary><b>飞书</b></summary>

1. 群设置 → 群机器人 → 添加机器人 → 自定义机器人
2. 复制 Webhook 地址到 `webhook` 字段
</details>

<details>
<summary><b>钉钉</b></summary>

1. 群设置 → 智能群助手 → 添加机器人 → 自定义（关键词模式）
2. 复制 Webhook 地址到 `webhook` 字段
3. 关键词需包含在通知内容中（项目名通常可满足）
</details>

<details>
<summary><b>Slack</b></summary>

1. 创建 [Slack App](https://api.slack.com/apps) → Incoming Webhooks → 启用
2. Add New Webhook to Workspace → 选择频道
3. 复制 Webhook URL 到 `webhook` 字段
</details>

<details>
<summary><b>Discord</b></summary>

1. 服务器设置 → 整合 → Webhooks → 新建
2. 选择频道，复制 Webhook URL 到 `webhook` 字段
</details>

## 监听事件

### Claude Code

| Hook | 触发时机 | 行为 |
|------|---------|------|
| Notification | 权限确认、等待输入等 | 分级推送 |
| Stop | Claude 回复结束 | 分级推送 |
| UserPromptSubmit | 用户发消息 | 清除 pending |
| PreToolUse | 用户点权限按钮 | 清除 pending |

### Codex CLI

| Hook | 触发时机 | 行为 |
|------|---------|------|
| PermissionRequest | Codex 请求授权时 | 分级推送 |
| Stop | Codex 回合结束 | 分级推送 |
| UserPromptSubmit | 用户发消息 | 清除 pending |
| PreToolUse | `request_user_input` 调用前 | 发送“需要回复”通知；其他工具清除当前 Session pending |
| PostToolUse | `request_user_input` 收到回答后 | 只取消当前 Session 尚未发送的输入通知 |

> Codex 没有独立的等待输入事件。插件通过 `PreToolUse(request_user_input)` 精确识别等待状态，并复用 `notification` 渠道配置。

### Reasonix

通过 `reasonix-plugin.json` 声明（`payloadFormat: "claude"`，脚本收到 Claude 形状的 stdin）：

| Hook | 触发时机 | 行为 |
|------|---------|------|
| Notification | 等待工具审批等需要用户注意时（`notification_type=permission_prompt`） | 分级推送 |
| Stop | 一轮对话结束（`last_assistant_message` 为摘要） | 分级推送 |
| UserPromptSubmit | 用户发消息 | 清除 pending / `/exit` 标记 |
| PreToolUse | `ask`（提问工具）调用前 | 发送"需要回复"通知；其他工具清除当前 Session pending |
| PostToolUse | `AskUserQuestion` 收到回答后 | 只取消当前 Session 尚未发送的输入通知 |

> Reasonix 的事件 key 与 Claude 一致（`hook_event_name`），脚本同时兼容 Reasonix 原生格式（`event`/`sessionId`/`lastAssistantText` 字段兜底）。安装后需重启 Reasonix 会话（`/new` 不会重新加载 hooks）。

### dsh（DeepSeek Harness）

通过宿主插件 `dsh-cc-notify` 订阅 dsh 拦截点（等价于外部 hook 的语义）：

| 拦截点 | 触发时机 | 行为 |
|------|---------|------|
| `approval/request` | 工具审批等待用户决策时 | 分级推送"需要确认"（代理 `next()`，永不代答） |
| `agent/turn-stopping` | 一轮结束的自然停止边界 | 分级推送"任务完成"（摘要来自 `assistant/message` 跟踪） |
| `agent/pre-step` | 用户提交消息后 | 清除 pending / `/exit` 标记 |
| `tools/pre-execute` | `ask_user_question` 调用前 | 发送"需要回复"通知；其他工具清除当前 Session pending |
| `tools/post-execute` | `ask_user_question` 返回后 | 只取消当前 Session 尚未发送的输入通知 |

> 插件只观察、不拦截：所有 waterfall 监听器都通过 `next()` 代理，绝不会阻塞或代答 dsh 的决策。

## 通知内容

通知先归一为统一字段，再按短通知和长通知分别渲染。标题使用实际 Agent 名，不再写死为 Claude。

| 场景 | 标题 |
|------|------|
| Claude Code Notification idle_prompt | `Claude Code · 等待响应 ⏳` |
| Codex PermissionRequest | `Codex · 需要确认 🔔` |
| Codex request_user_input | `Codex · 需要回复 🔔` |
| Reasonix Notification（等待审批） | `Reasonix · 需要确认 🔔` |
| Reasonix `ask` 提问 | `Reasonix · 需要回复 🔔` |
| dsh `approval/request` | `dsh · 需要确认 🔔` |
| dsh `ask_user_question` | `dsh · 需要回复 🔔` |
| Stop | `{Agent} · 任务完成 ✅` |
| 异常 / 未知事件 | `{Agent} · 异常 ⚠️` |

Agent 名识别顺序：`CC_NOTIFY_AGENT` 环境变量（显式覆盖）→ Reasonix 插件环境 `REASONIX_PLUGIN_ROOT` → dsh 插件环境 `DSH_CC_NOTIFY` → 事件/path 特征（Notification 或 `.claude` 路径 → Claude Code，否则 Codex）。

短通知正文只保留打断所需信息：

```text
[项目名] summary_short · tool_name
```

其中 `tool_name` 是条件字段，没有就不显示；`permission_mode` 不进入通知正文。

Codex 等待输入使用专用短正文，包含问题数和短 Session id：

```text
[项目名] 首个问题摘要 · 2 个问题 · Session 019eabcd
```

长通知正文第一行显示 `summary_short`，随后显示定位字段：

```text
summary_short

项目: project
事件: hook_event_name
工具: tool_name      # 有值才显示
Session: session_short

model · cwd · hostname
```

等待输入的长通知额外显示问题数、首题选项和完整 Session id。飞书默认发送消息卡片；企业微信、钉钉、Slack 使用近似 Markdown 模板；Discord 使用 embed。`summary_short` 来自 `message/prompt`、首个结构化问题或 `last_assistant_message` 的首个非空行，最长保留 120 字。

## 过滤规则

| 规则 | 说明 |
|------|------|
| 子智能体过滤 | `agent_id` 非空时跳过 |
| Stop 循环保护 | `stop_hook_active=true` 时跳过 |
| `/exit` 静默 | 只抑制当前 Session 后续的 Stop 事件 |
| Rate Limiting | 按 Session + 事件类别限流；`request_user_input` 使用 `tool_use_id` 精确去重 |

## 文件结构

```
cc-notify-hooks/
├── .claude-plugin/
│   ├── plugin.json -> ../plugins/cc-notify-hooks/.claude-plugin/plugin.json
│   └── marketplace.json     # Claude Code marketplace（指向 plugins/cc-notify-hooks）
├── .codex-plugin/
│   └── plugin.json -> ../plugins/cc-notify-hooks/.codex-plugin/plugin.json
├── .agents/plugins/
│   └── marketplace.json     # Codex CLI marketplace（指向 plugins/cc-notify-hooks）
├── plugins/cc-notify-hooks/ # 真实插件根目录，Claude/Codex/Reasonix/dsh 都从这里安装
│   ├── .claude-plugin/plugin.json
│   ├── .codex-plugin/plugin.json
│   ├── reasonix-plugin.json # Reasonix 原生插件清单（v2，5 个 hook）
│   ├── dsh-plugin/          # dsh 宿主插件（零依赖 cordis 插件）
│   │   ├── package.json
│   │   ├── index.js
│   │   └── test/plugin.test.mjs
│   ├── skills/config/SKILL.md
│   ├── hooks/
│   │   ├── hooks.json
│   │   └── codex-hooks.json
│   ├── scripts/
│   │   ├── notify.sh
│   │   ├── pre_tool_use.sh
│   │   ├── clear_pending.sh
│   │   └── channels/
│   ├── config/notify.example.json
│   └── test_notify.sh
├── skills -> plugins/cc-notify-hooks/skills
├── hooks -> plugins/cc-notify-hooks/hooks
├── scripts -> plugins/cc-notify-hooks/scripts
├── config -> plugins/cc-notify-hooks/config
├── install.sh               # 独立安装入口（路由）
├── install/
│   ├── claude.sh            # Claude Code 安装分支
│   ├── codex.sh             # Codex CLI 安装分支
│   ├── reasonix.sh          # Reasonix 安装分支（reasonix plugin install --link）
│   └── dsh.sh               # dsh 安装分支（软链插件 + cordis.patch.yml insert）
└── test_notify.sh -> plugins/cc-notify-hooks/test_notify.sh
```

调试日志：`/tmp/claude-hooks-debug.log`

## 卸载

**Claude Code 插件**：在 Claude Code 中 `/plugin` 管理。

**Codex CLI 插件**：在 Codex 中 `/plugin` 管理。

**独立安装（Claude）**：
```bash
rm -rf ~/.claude/hooks/scripts ~/.claude/hooks/notify.json ~/.claude/hooks/state
# 手动编辑 ~/.claude/settings.json 移除相关 hooks
```

**独立安装（Codex）**：
```bash
rm -rf ~/.codex/cc-notify-hooks
# 手动编辑 ~/.codex/hooks.json 移除相关事件，可选关闭 codex_hooks
```

**独立安装（Reasonix）**：
```bash
reasonix plugin remove cc-notify-hooks --yes
rm -rf ~/.reasonix/cc-notify-hooks
```

**独立安装（dsh）**：
```bash
rm -f ~/node_modules/@dsh-local/dsh-cc-notify
# 手动编辑 ~/.dsh/cordis.patch.yml，删除 cc-notify-hooks 的 insert 条目
rm -rf ~/.dsh/cc-notify-hooks
```

## License

MIT
