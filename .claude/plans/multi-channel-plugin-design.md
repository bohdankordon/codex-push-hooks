# cc-notify-hooks v2: multi-channel plugin design

**Date**: 2026-03-22
**Status**: Approved

## Overview

Restructure cc-notify-hooks from a 3-channel shell script into a Claude Code plugin with 11 notification channels, a JSON configuration, a modular channel architecture, and a tiered push model whose preset delays can be overridden.

## Decision record

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tiering model | Presets plus overridable delay | Usable with zero configuration, tunable for advanced users |
| Configuration format | JSON | Structured, and jq is already a required dependency so nothing new is needed |
| Plugin strategy | Develop directly in the plugin layout | Test with `claude --plugin-dir` and get it right in one step |
| Architecture | Modular channels (one file per channel) | Single responsibility: adding a channel never touches the main logic |
| Channel scope | All 11 channels from v1 | Each channel is essentially one curl call; once the architecture is in place, adding one is just filling in a template |

## Supported channels

| Channel | Type | Default delay | Default events | Credential fields |
|---------|------|---------------|----------------|-------------------|
| macos | Local osascript | 3s | notification | none (zero configuration) |
| bark | Push service | 15s | notification, stop | key, server |
| telegram | Bot API | 5s | notification, stop | bot_token, chat_id |
| pushover | Push service | 15s | notification, stop | app_token, user_key |
| ntfy | Push service | 15s | notification, stop | topic, server |
| gotify | Self-hosted push | 15s | notification, stop | server, app_token |
| wechat | Webhook | 300s | notification, stop | webhook |
| feishu | Webhook | 300s | notification, stop | webhook |
| dingtalk | Webhook | 300s | notification, stop | webhook |
| slack | Webhook | 300s | notification, stop | webhook |
| discord | Webhook | 300s | notification, stop | webhook |

## Plugin directory structure

```
cc-notify-hooks/
├── .claude-plugin/
│   └── plugin.json              # plugin manifest
├── hooks/
│   └── hooks.json               # hook event definitions
├── scripts/
│   ├── notify.sh                # main dispatcher
│   ├── clear_pending.sh         # clear pending markers on user interaction
│   └── channels/                # one file per channel
│       ├── macos.sh
│       ├── bark.sh
│       ├── telegram.sh
│       ├── wechat.sh
│       ├── feishu.sh
│       ├── dingtalk.sh
│       ├── slack.sh
│       ├── discord.sh
│       ├── pushover.sh
│       ├── ntfy.sh
│       └── gotify.sh
├── config/
│   └── notify.example.json      # configuration template
├── install.sh                   # install entry point for non-plugin users
├── test_notify.sh               # connectivity tests
├── README.md
└── LICENSE
```

## JSON configuration structure

Location precedence: `${CLAUDE_PLUGIN_DATA}/notify.json` → `~/.claude/hooks/notify.json` → macOS notifications only

```json
{
  "channels": {
    "macos": {
      "enabled": true,
      "delay": 3,
      "sound": "Glass",
      "events": ["notification"]
    },
    "bark": {
      "enabled": true,
      "delay": 15,
      "key": "your-bark-key",
      "server": "https://api.day.app"
    },
    "telegram": {
      "enabled": false,
      "delay": 5,
      "bot_token": "123456:ABC-DEF...",
      "chat_id": "123456789"
    },
    "pushover": {
      "enabled": false,
      "delay": 15,
      "app_token": "xxx",
      "user_key": "xxx"
    },
    "ntfy": {
      "enabled": false,
      "delay": 15,
      "topic": "my-claude",
      "server": "https://ntfy.sh"
    },
    "gotify": {
      "enabled": false,
      "delay": 15,
      "server": "https://gotify.example.com",
      "app_token": "xxx"
    },
    "wechat": {
      "enabled": false,
      "delay": 300,
      "webhook": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"
    },
    "feishu": {
      "enabled": false,
      "delay": 300,
      "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"
    },
    "dingtalk": {
      "enabled": false,
      "delay": 300,
      "webhook": "https://oapi.dingtalk.com/robot/send?access_token=xxx"
    },
    "slack": {
      "enabled": false,
      "delay": 300,
      "webhook": "https://hooks.slack.com/services/T.../B.../xxx"
    },
    "discord": {
      "enabled": false,
      "delay": 300,
      "webhook": "https://discord.com/api/webhooks/xxx/xxx"
    }
  },
  "rate_limit": 10
}
```

### Field reference

- **enabled**: explicit switch; a channel is skipped when it is `false` or missing
- **delay**: seconds; adjustable per channel (preset plus override)
- **events**: optional, defaults to `["notification", "stop"]`; macOS defaults to `["notification"]` only
- **channel-specific fields**: each channel carries only the credentials it needs, with no redundancy

## Channel script interface

Uniform function signature:

```bash
# send_<channel_name> <title> <body> <channel_config_json>
send_bark() {
    local title="$1" body="$2" config="$3"
    local key=$(echo "$config" | jq -r '.key')
    local server=$(echo "$config" | jq -r '.server // "https://api.day.app"')
    curl -sf --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg k "$key" --arg t "$title" --arg b "$body" \
            '{device_key:$k, title:$t, body:$b, level:"timeSensitive", group:"claude-code"}')" \
        "${server}/push" >/dev/null 2>&1 || true
}
```

**Conventions:**
- The function name `send_<name>` matches the key in the configuration
- Arguments: title, body, and the channel's JSON config object
- No pending checks and no sleeps (pure sending)
- Failures are non-fatal (`|| true`)

## Pipeline orchestration

```
notify.sh main flow:
1. Read the configuration JSON
2. Read the event JSON from stdin → parse the fields
3. Filtering rules: subagents / loop protection / /exit / rate limit
4. Build title + body
5. Create the pending file
6. Build the send queue:
   enabled=true + events match → sort by ascending delay
   → [(macos,3), (telegram,5), (bark,15), (ntfy,15), (wechat,300), ...]
7. Background subshell:
   elapsed=0
   for (channel, delay) in sorted_queue:
       wait = delay - elapsed
       sleep $wait
       if pending does not exist: exit
       source channels/<channel>.sh
       send_<channel> "$title" "$body" "$channel_config"
       elapsed = delay
   rm pending
```

**Key design points:**
- Channels that share a delay are sent one after another in the same round, with no extra sleep
- The pending check runs once per delay step (a batch with the same delay is either sent entirely or skipped entirely)
- The whole pipeline is a background subshell (`(...) &`) that never blocks the hook from returning

## Hook configuration (hooks/hooks.json)

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh notification",
          "timeout": 5
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh stop",
          "timeout": 5
        }]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/scripts/clear_pending.sh",
          "timeout": 3
        }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/scripts/clear_pending.sh",
          "timeout": 3
        }]
      }
    ]
  }
}
```

## install.sh changes

```
[1/4] Check dependencies (jq, curl)
[2/4] Choose the channels to enable
      → list every channel and let the user multi-select by number
      → prompt for credentials for each enabled channel
      → show current values as defaults when a configuration already exists
[3/4] Install the scripts
      → copy scripts/ (including channels/) to ~/.claude/hooks/
      → generate ~/.claude/hooks/notify.json
[4/4] Configure hooks
      → replace ${CLAUDE_PLUGIN_ROOT} in hooks.json with ~/.claude/hooks
      → merge into ~/.claude/settings.json
```

## test_notify.sh changes

```bash
bash test_notify.sh              # test every enabled channel
bash test_notify.sh bark         # test a single channel
bash test_notify.sh hook         # simulate the full pipeline
bash test_notify.sh list         # list enabled channels and delays
```

## Filtering rules (unchanged)

- Subagents: skip when agent_id is non-empty
- Stop-loop protection: skip when stop_hook_active=true
- /exit silence: skip when the exiting marker exists
- Rate limiting: the same event category is pushed only once per rate_limit seconds

## Migration compatibility

- When v1 users run the new install.sh, an existing `notify.conf` is detected and migrated to `notify.json` automatically
- Environment variables (BARK_KEY and so on) are no longer a configuration source; only the JSON configuration file is
- macOS users can still run with zero configuration when no configuration file exists (fallback behavior)

## Channel API references

### Bark
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"device_key":"KEY","title":"T","body":"B","level":"timeSensitive","group":"claude-code"}' \
  "https://api.day.app/push"
```

### Telegram
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"chat_id":"CHAT_ID","text":"T\nB","parse_mode":"HTML"}' \
  "https://api.telegram.org/botTOKEN/sendMessage"
```

### WeCom
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"msgtype":"text","text":{"content":"T\nB"}}' \
  "WEBHOOK_URL"
```

### Feishu
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"msg_type":"text","content":{"text":"T\nB"}}' \
  "WEBHOOK_URL"
```

### DingTalk
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"msgtype":"text","text":{"content":"T\nB"}}' \
  "WEBHOOK_URL"
```

### Slack
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"text":"*T*\nB"}' \
  "WEBHOOK_URL"
```

### Discord
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"content":"**T**\nB"}' \
  "WEBHOOK_URL"
```

### Pushover
```bash
curl -sf --max-time 10 \
  -d "token=APP_TOKEN&user=USER_KEY&title=T&message=B" \
  "https://api.pushover.net/1/messages.json"
```

### ntfy
```bash
curl -sf --max-time 10 -H "Title: T" -H "Priority: 4" \
  -d "B" \
  "https://ntfy.sh/TOPIC"
```

### Gotify
```bash
curl -sf --max-time 10 -H "Content-Type: application/json" \
  -d '{"title":"T","message":"B","priority":5}' \
  "https://gotify.example.com/message?token=APP_TOKEN"
```
