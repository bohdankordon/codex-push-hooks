# cc-notify-hooks

Tiered push notifications for **Claude Code**, **Codex CLI**, **Reasonix**, and **dsh (DeepSeek Harness)**. It supports **11 notification channels** and works either as a plugin or as standalone scripts, with every agent sharing a single configuration.

## Why tiered notifications?

Tasks run by Claude Code, Codex, Reasonix, and dsh take anywhere from a few seconds to tens of minutes. You will not keep staring at the terminal, but you do need to come back at the right moment.

**cc-notify-hooks splits notifications into two tiers:**

**Short-delay notifications (seconds)** — you may have just switched to a browser or a chat window. Instant-reach channels such as desktop notifications and phone pushes remind you that "Claude needs you" within seconds. If you see the notification and come back, the queued pushes are cancelled automatically and you are not bothered again.

**Fallback notifications (minutes)** — you may have left the computer, joined a meeting, or stepped away from your phone. Team and asynchronous channels such as WeCom groups, Feishu groups, and Slack channels follow up after a few minutes. Even if you miss the short-delay notification, you can still see the task status in the tools your team already uses.

**How it works underneath**: every push checks whether the user has already responded (that is, whether the pending file still exists). As soon as you come back and interact, the queued pushes for the current session are voided, while other sessions running in parallel are unaffected. If a short-delay notification already solved the problem, the fallback notification is never sent.

## Supported channels

### Short-delay channels (instant reach)

Suited to switching windows or stepping away briefly.

| Channel | Default delay | Notes |
|---------|---------------|-------|
| **macOS** | 3s | Zero configuration, native system notifications |
| **Telegram** | 5s | Bot message, instant phone push |
| **Bark** | 15s | Push for iOS / macOS / Android |
| **Pushover** | 15s | Cross-platform push service |
| **ntfy** | 15s | Open-source push, self-hosting supported |
| **Gotify** | 15s | Self-hosted push service |

### Fallback channels (async safety net)

Suited to leaving the desk, joining meetings, or keeping a team informed.

| Channel | Default delay | Notes |
|---------|---------------|-------|
| **WeCom** | 5min | Group robot webhook |
| **Feishu** | 5min | Group robot webhook |
| **DingTalk** | 5min | Group robot webhook |
| **Slack** | 5min | Incoming Webhook |
| **Discord** | 5min | Channel Webhook |

Each channel has its own configurable delay. Enable only the channels you need; the rest are skipped automatically.

## How it works

```
Claude Code / Codex CLI events
    │
    ├─ Codex request_user_input → PreToolUse dispatcher → waiting-for-input notification
    │                                      └─ PostToolUse → targeted cancel
    ▼
notify.sh ── clear stale pending for this session → create a new pending marker
    │
    │  ┌── Short-delay notifications ─────────────────────┐
    ├─ │ 3s  → pending still there? → macOS notification   │
    ├─ │ 5s  → pending still there? → Telegram             │
    ├─ │ 15s → pending still there? → Bark / ntfy / ...    │
    │  └──────────────────────────────────────────────────┘
    │  ┌── Fallback notifications ────────────────────────┐
    └─ │ 5m  → pending still there? → WeCom / Feishu /     │
       │                             DingTalk / Slack      │
       └──────────────────────────────────────────────────┘

User comes back (sends a message / answers a question / clicks an approval button)
    └─→ clear_pending.sh → clear this session's pending → all queued pushes cancelled
         (the short-delay notification already did its job, so the fallback stays quiet)
```

## Installation

### Requirements

- **jq** — JSON parsing (`brew install jq` / `apt install jq`)
- **curl** — sending pushes (usually preinstalled)

### Option 1: Claude Code marketplace (recommended for Claude users)

In Claude Code, run:

```
/plugin marketplace add MarioZZJ/cc-notify-hooks
/plugin install cc-notify-hooks@cc-notify-hooks
```

After installing, run `/reload-plugins` to refresh, then run `/cc-notify-hooks:config` to start the interactive configuration wizard (see [Configuration](#configuration) below).

### Option 2: Codex CLI marketplace (recommended for Codex users)

`.agents/plugins/marketplace.json` at the repository root is the Codex marketplace, and the actual plugin directory is `plugins/cc-notify-hooks/`. In your terminal, run:

```bash
codex plugin marketplace add MarioZZJ/cc-notify-hooks --ref v2.4.0
codex plugin add cc-notify-hooks@cc-notify-hooks
```

Enable hooks (required; Codex disables them by default) by adding this to `~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
```

Then restart Codex, or use the plugin in a new session. After installing or upgrading, open `/hooks` to review and trust the new or changed hook definitions, otherwise Codex skips them.

Note: Codex runs hook commands from the session `cwd`, not from the plugin root. `.codex-plugin/plugin.json` only packages `hooks/codex-hooks.json` as the lifecycle configuration; hook commands cannot be written as `./scripts/...`. This plugin locates its scripts through the `PLUGIN_ROOT` variable provided by Codex and stores plugin configuration and state in `PLUGIN_DATA`, so it works with a custom `CODEX_HOME` and does not depend on a fixed plugin cache path.

### Option 3: Local plugin mode

```bash
git clone https://github.com/MarioZZJ/cc-notify-hooks.git

# Claude Code
claude --plugin-dir ./cc-notify-hooks/plugins/cc-notify-hooks

# Codex CLI: see the Codex marketplace option above
```

### Option 4: Standalone installation (no plugin)

```bash
git clone https://github.com/MarioZZJ/cc-notify-hooks.git
cd cc-notify-hooks
bash install.sh                  # interactively choose Claude Code / Codex / Reasonix / dsh
bash install.sh claude           # install into Claude Code directly
bash install.sh codex            # install into Codex CLI directly
bash install.sh reasonix         # install into Reasonix directly
bash install.sh dsh              # install into dsh (DeepSeek Harness) directly
```

The installer walks you through channel selection and credential entry, then generates the configuration for you:

- **Claude branch**: writes `~/.claude/hooks/notify.json` and merges hooks into `~/.claude/settings.json`
- **Codex branch**: writes `~/.codex/cc-notify-hooks/notify.json`, merges hooks into `~/.codex/hooks.json`, and reminds you to enable `codex_hooks`
- **Reasonix branch**: writes `~/.reasonix/cc-notify-hooks/notify.json` and registers this repository as a plugin with `reasonix plugin install --link` (`reasonix-plugin.json` declares 5 hooks)
- **dsh branch**: writes `~/.dsh/cc-notify-hooks/notify.json`, symlinks the plugin package into `~/node_modules/@dsh-local/dsh-cc-notify`, and appends an insert entry to `~/.dsh/cordis.patch.yml` (dsh hot-loads it, no restart required)

**After a Claude install, run `/reload-plugins` to refresh; after a Codex install, restart the Codex process; after a Reasonix install, restart the session; a dsh install takes effect immediately.**

### Option 5: Reasonix plugin package (recommended for Reasonix users)

Reasonix natively supports this repository's `reasonix-plugin.json` (`reasonix.io/plugin/v2`), installable from the GitHub repository or from a local directory:

```bash
# From GitHub (the repository root is a compatible Claude marketplace and installs plugins/cc-notify-hooks)
reasonix plugin install git:github.com/MarioZZJ/cc-notify-hooks --yes

# Or link a local clone (development mode: repository changes take effect immediately)
git clone https://github.com/MarioZZJ/cc-notify-hooks.git
reasonix plugin install ./cc-notify-hooks/plugins/cc-notify-hooks --link --yes
```

After installing:

```bash
reasonix plugin show cc-notify-hooks   # inspect the 5 hooks
reasonix hook list --json              # confirm the hooks are loaded
```

Plugin hooks use `payloadFormat: "claude"`, so the scripts receive stdin with the same fields as Claude Code (`hook_event_name`/`session_id`/`message`…) and share the same `notify.sh`. The configuration file lives at `~/.reasonix/cc-notify-hooks/notify.json` (the scripts also accept `~/.claude/hooks/notify.json` or `~/.codex/cc-notify-hooks/notify.json`, searched in order).

### Option 6: dsh plugin (DeepSeek Harness)

dsh has no external shell hooks, so this repository ships a zero-dependency host plugin, `dsh-cc-notify` (`plugins/cc-notify-hooks/dsh-plugin/`), that subscribes directly to dsh interception points (`approval/request`, `agent/turn-stopping`, `agent/pre-step`, `tools/pre-execute`, `tools/post-execute`) and calls the same `scripts/`.

The recommended path is the standalone installer:

```bash
cd cc-notify-hooks && bash install/dsh.sh
```

It does three things: symlinks the plugin package into `~/node_modules/@dsh-local/dsh-cc-notify`, writes `~/.dsh/cc-notify-hooks/notify.json`, and appends this to `~/.dsh/cordis.patch.yml`:

```yaml
- insert:
    - id: cc-notify-hooks
      name: '@dsh-local/dsh-cc-notify'
      config:
        scriptsDir: /path/to/cc-notify-hooks/plugins/cc-notify-hooks/scripts
        stateDir: /home/you/.claude/hooks/state
```

dsh hot-loads `~/.dsh/cordis.patch.yml`, so running sessions pick it up immediately (`dsh web --dump-config` confirms the entry made it into the composition tree). Plugin unit tests:

```bash
node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs
```

### Verification

```bash
bash test_notify.sh              # test every enabled channel
bash test_notify.sh bark         # test a single channel
bash test_notify.sh list         # show enabled channels and their delays
bash test_notify.sh hook         # simulate the Claude Code hook flow
bash test_notify.sh codex        # simulate a Codex CLI PermissionRequest event
bash test_notify.sh codex-plugin-hooks  # verify Codex plugin hook path resolution
bash test_notify.sh user-input   # verify the request_user_input dispatcher and templates
bash test_notify.sh state        # verify multi-session state isolation and exact deduplication
bash test_notify.sh render       # verify the notification content templates
bash test_notify.sh agents       # verify Reasonix / dsh agent detection and event fields
node plugins/cc-notify-hooks/dsh-plugin/test/plugin.test.mjs  # dsh plugin unit tests
```

## Configuration

### Option 1: Interactive configuration (recommended)

In Claude Code, run:

```
/cc-notify-hooks:config
```

The wizard walks you through:
1. Choosing the **short-delay channels** to enable (macOS, Telegram, Bark, and so on)
2. Choosing the **fallback channels** to enable (WeCom, Feishu, Slack, and so on)
3. Entering credentials for each channel, with guidance on where to find them
4. Adjusting delays
5. Testing channel connectivity

Channels that are already configured show their current state, and you can change them at any time.

### Option 2: Editing the configuration file manually

Create `~/.claude/hooks/notify.json`, either by fetching the template or by copying a local clone:

```bash
# marketplace install: fetch the template from the project repository
curl -sL https://raw.githubusercontent.com/MarioZZJ/cc-notify-hooks/main/plugins/cc-notify-hooks/config/notify.example.json \
  -o ~/.claude/hooks/notify.json

# local clone: copy it directly
cp config/notify.example.json ~/.claude/hooks/notify.json
```

Then edit the file: set `"enabled": true` for the channels you need and fill in their credentials:

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

The complete template is in [`config/notify.example.json`](config/notify.example.json).

### Field reference

| Field | Description |
|-------|-------------|
| `enabled` | Whether the channel is enabled |
| `delay` | Push delay in seconds; adjust freely |
| `events` | Optional list of event types to respond to; defaults to `["notification", "stop"]`. Codex waiting-for-input events are tagged internally as `user_input` while channel filtering still uses `notification`, so existing configurations need no changes |
| `format` | Optional display format for fallback channels. Feishu defaults to `card`, WeCom/DingTalk/Slack default to `markdown`, Discord defaults to `embed` |
| Other fields | Channel-specific credentials (key, webhook, token, and so on) |

### Channel credentials

<details>
<summary><b>Bark</b></summary>

1. Install the [Bark app](https://github.com/Finb/Bark)
2. The push URL on the home screen looks like `https://api.day.app/xxxxxxxx`; `xxxxxxxx` is the `key`
3. For a self-hosted server, set the `server` field
</details>

<details>
<summary><b>Telegram</b></summary>

1. Find [@BotFather](https://t.me/BotFather) in Telegram, create a bot, and copy its `bot_token`
2. Send your bot a message
3. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` to get the `chat_id`
</details>

<details>
<summary><b>Pushover</b></summary>

1. Register at [pushover.net](https://pushover.net) and get your `user_key`
2. Create an application and get its `app_token`
</details>

<details>
<summary><b>ntfy</b></summary>

1. Install the [ntfy app](https://ntfy.sh) and subscribe to a topic
2. Set the `topic` field; for a self-hosted server, set `server`
</details>

<details>
<summary><b>Gotify</b></summary>

1. Self-host a [Gotify](https://gotify.net) instance
2. Create an application and get its `app_token`
3. Set `server` and `app_token`
</details>

<details>
<summary><b>WeCom</b></summary>

1. Group chat → "⋯" in the top right → Group Robot → Add → Create
2. Copy the webhook URL into the `webhook` field
</details>

<details>
<summary><b>Feishu</b></summary>

1. Group settings → Group Bots → Add Bot → Custom Bot
2. Copy the webhook URL into the `webhook` field
</details>

<details>
<summary><b>DingTalk</b></summary>

1. Group settings → Smart Group Assistant → Add Robot → Custom (keyword mode)
2. Copy the webhook URL into the `webhook` field
3. The keyword must appear in the notification content (the project name usually satisfies this)
</details>

<details>
<summary><b>Slack</b></summary>

1. Create a [Slack app](https://api.slack.com/apps) → Incoming Webhooks → enable
2. Add New Webhook to Workspace → choose a channel
3. Copy the webhook URL into the `webhook` field
</details>

<details>
<summary><b>Discord</b></summary>

1. Server settings → Integrations → Webhooks → New Webhook
2. Choose a channel and copy the webhook URL into the `webhook` field
</details>

## Events we listen to

### Claude Code

| Hook | Trigger | Behavior |
|------|---------|----------|
| Notification | Permission prompts, waiting for input, and similar | Tiered push |
| Stop | Claude finishes a reply | Tiered push |
| UserPromptSubmit | User sends a message | Clear pending |
| PreToolUse | User clicks an approval button | Clear pending |

### Codex CLI

| Hook | Trigger | Behavior |
|------|---------|----------|
| PermissionRequest | Codex asks for authorization | Tiered push |
| Stop | Codex finishes a turn | Tiered push |
| UserPromptSubmit | User sends a message | Clear pending |
| PreToolUse | Before a `request_user_input` call | Send a "reply needed" notification; other tools clear the current session's pending markers |
| PostToolUse | After `request_user_input` receives an answer | Cancel only the input notifications for the current session that have not been sent yet |

> Codex has no dedicated waiting-for-input event. The plugin detects the waiting state precisely through `PreToolUse(request_user_input)` and reuses the `notification` channel configuration.

### Reasonix

Declared in `reasonix-plugin.json` (`payloadFormat: "claude"`, so the scripts receive Claude-shaped stdin):

| Hook | Trigger | Behavior |
|------|---------|----------|
| Notification | When user attention is needed, such as waiting for tool approval (`notification_type=permission_prompt`) | Tiered push |
| Stop | A conversation turn ends (`last_assistant_message` carries the summary) | Tiered push |
| UserPromptSubmit | User sends a message | Clear pending / mark `/exit` |
| PreToolUse | Before an `ask` (question tool) call | Send a "reply needed" notification; other tools clear the current session's pending markers |
| PostToolUse | After `AskUserQuestion` receives an answer | Cancel only the input notifications for the current session that have not been sent yet |

> Reasonix event keys match Claude's (`hook_event_name`), and the scripts also accept Reasonix's native format as a fallback (`event`/`sessionId`/`lastAssistantText` fields). Restart the Reasonix session after installing (`/new` does not reload hooks).

### dsh (DeepSeek Harness)

The host plugin `dsh-cc-notify` subscribes to dsh interception points (equivalent to external hook semantics):

| Interception point | Trigger | Behavior |
|--------------------|---------|----------|
| `approval/request` | Tool approval waiting for a user decision | Tiered push of "approval needed" (proxies `next()`, never answers on your behalf) |
| `agent/turn-stopping` | Natural stopping boundary at the end of a turn | Tiered push of "task complete" (summary tracked from `assistant/message`) |
| `agent/pre-step` | After the user submits a message | Clear pending / mark `/exit` |
| `tools/pre-execute` | Before an `ask_user_question` call | Send a "reply needed" notification; other tools clear the current session's pending markers |
| `tools/post-execute` | After `ask_user_question` returns | Cancel only the input notifications for the current session that have not been sent yet |

> The plugin only observes; it never intercepts. Every waterfall listener delegates through `next()` and never blocks or answers a dsh decision.

## Notification content

Notifications are first normalized into a shared set of fields, then rendered separately for short-delay and fallback channels. Titles use the actual agent name instead of being hard-coded to Claude.

| Scenario | Title |
|----------|-------|
| Claude Code Notification idle_prompt | `Claude Code · Awaiting response ⏳` |
| Codex PermissionRequest | `Codex · Approval needed 🔔` |
| Codex request_user_input | `Codex · Reply needed 🔔` |
| Reasonix Notification (waiting for approval) | `Reasonix · Approval needed 🔔` |
| Reasonix `ask` question | `Reasonix · Reply needed 🔔` |
| dsh `approval/request` | `dsh · Approval needed 🔔` |
| dsh `ask_user_question` | `dsh · Reply needed 🔔` |
| Stop | `{Agent} · Task complete ✅` |
| Error / unknown event | `{Agent} · Error ⚠️` |

Agent detection order: the `CC_NOTIFY_AGENT` environment variable (an explicit override) → the Reasonix plugin environment `REASONIX_PLUGIN_ROOT` → the dsh plugin environment `DSH_CC_NOTIFY` → event/path characteristics (a Notification event or a `.claude` path means Claude Code, otherwise Codex).

Short-delay bodies keep only what you need to interrupt your work:

```text
[project] summary_short · tool_name
```

`tool_name` is conditional and omitted when empty; `permission_mode` never appears in the notification body.

Codex waiting-for-input events use a dedicated short body with the question count and a short session id:

```text
[project] first question summary · 2 questions · Session 019eabcd
```

Fallback bodies show `summary_short` on the first line, followed by locating fields:

```text
summary_short

Project: project
Event: hook_event_name
Tool: tool_name      # shown only when present
Session: session_short

model · cwd · hostname
```

Fallback notifications for waiting-for-input also show the number of questions, the first question's options, and the full session id. Feishu sends a message card by default; WeCom, DingTalk, and Slack use an approximate Markdown template; Discord uses an embed. `summary_short` comes from `message/prompt`, the first structured question, or the first non-empty line of `last_assistant_message`, truncated to 120 characters.

## Filtering rules

| Rule | Description |
|------|-------------|
| Subagent filtering | Skip when `agent_id` is non-empty |
| Stop-loop protection | Skip when `stop_hook_active=true` |
| `/exit` silence | Suppress only subsequent Stop events for the current session |
| Rate limiting | Throttled per session and event category; `request_user_input` deduplicates precisely by `tool_use_id` |

## File structure

```
cc-notify-hooks/
├── .claude-plugin/
│   ├── plugin.json -> ../plugins/cc-notify-hooks/.claude-plugin/plugin.json
│   └── marketplace.json     # Claude Code marketplace (points at plugins/cc-notify-hooks)
├── .codex-plugin/
│   └── plugin.json -> ../plugins/cc-notify-hooks/.codex-plugin/plugin.json
├── .agents/plugins/
│   └── marketplace.json     # Codex CLI marketplace (points at plugins/cc-notify-hooks)
├── plugins/cc-notify-hooks/ # the real plugin root; Claude/Codex/Reasonix/dsh all install from here
│   ├── .claude-plugin/plugin.json
│   ├── .codex-plugin/plugin.json
│   ├── reasonix-plugin.json # native Reasonix plugin manifest (v2, 5 hooks)
│   ├── dsh-plugin/          # dsh host plugin (zero-dependency cordis plugin)
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
├── install.sh               # standalone installer entry point (router)
├── install/
│   ├── claude.sh            # Claude Code install branch
│   ├── codex.sh             # Codex CLI install branch
│   ├── reasonix.sh          # Reasonix install branch (reasonix plugin install --link)
│   └── dsh.sh               # dsh install branch (plugin symlink + cordis.patch.yml insert)
└── test_notify.sh -> plugins/cc-notify-hooks/test_notify.sh
```

Debug log: `/tmp/claude-hooks-debug.log`

## Uninstall

**Claude Code plugin**: manage it with `/plugin` inside Claude Code.

**Codex CLI plugin**: manage it with `/plugin` inside Codex.

**Standalone install (Claude)**:
```bash
rm -rf ~/.claude/hooks/scripts ~/.claude/hooks/notify.json ~/.claude/hooks/state
# edit ~/.claude/settings.json manually to remove the related hooks
```

**Standalone install (Codex)**:
```bash
rm -rf ~/.codex/cc-notify-hooks
# edit ~/.codex/hooks.json manually to remove the related events; optionally turn off codex_hooks
```

**Standalone install (Reasonix)**:
```bash
reasonix plugin remove cc-notify-hooks --yes
rm -rf ~/.reasonix/cc-notify-hooks
```

**Standalone install (dsh)**:
```bash
rm -f ~/node_modules/@dsh-local/dsh-cc-notify
# edit ~/.dsh/cordis.patch.yml manually and delete the cc-notify-hooks insert entry
rm -rf ~/.dsh/cc-notify-hooks
```

## License

MIT
