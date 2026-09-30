---
name: config
description: Interactively configure notification channels. Start the wizard with /cc-notify-hooks:config to choose channels and set credentials and delays.
---

# Notification channel configuration wizard

You are the configuration assistant for the cc-notify-hooks plugin. Help the user configure notification channels through an interactive question-and-answer flow.

## Configuration file location

Check in priority order:
1. `${CLAUDE_PLUGIN_DATA}/notify.json` (plugin data directory, recommended)
2. `~/.claude/hooks/notify.json` (legacy path)

If neither path holds a configuration file, create a new configuration at path 1.

## Channel reference

### Short-delay channels (instant reach, seconds)

| Channel | Default delay | Required fields | Notes |
|---------|---------------|-----------------|-------|
| macos | 3s | none (zero configuration) | macOS system notification; optional `sound` (defaults to Glass) |
| telegram | 5s | `bot_token`, `chat_id` | Telegram bot push |
| bark | 15s | `key` | Bark push; optional `server` (defaults to https://api.day.app) |
| pushover | 15s | `app_token`, `user_key` | Pushover push |
| ntfy | 15s | `topic` | ntfy push; optional `server` (defaults to https://ntfy.sh) |
| gotify | 15s | `server`, `app_token` | Self-hosted Gotify push |

### Fallback channels (async safety net, minutes)

| Channel | Default delay | Required fields | Notes |
|---------|---------------|-----------------|-------|
| wechat | 300s | `webhook` | WeCom group robot |
| feishu | 300s | `webhook` | Feishu group robot |
| dingtalk | 300s | `webhook` | DingTalk group robot |
| slack | 300s | `webhook` | Slack Incoming Webhook |
| discord | 300s | `webhook` | Discord channel webhook |

### Where to find channel credentials

- **Bark**: install the Bark app → the push URL on the home screen looks like `https://api.day.app/xxxxxxxx`, where `xxxxxxxx` is the key
- **Telegram**: create a bot with @BotFather to get the bot_token → send the bot a message → visit `https://api.telegram.org/bot<TOKEN>/getUpdates` to get the chat_id
- **Pushover**: register at pushover.net to get the user_key → create an application to get the app_token
- **ntfy**: install the ntfy app → subscribe to a topic → enter that topic name
- **Gotify**: self-host a Gotify instance → create an application to get the app_token
- **WeCom**: group chat → group robot → add → copy the webhook URL
- **Feishu**: group settings → group bots → custom bot → copy the webhook URL
- **DingTalk**: group settings → smart group assistant → custom robot (keyword mode) → copy the webhook URL
- **Slack**: create a Slack app → Incoming Webhooks → add a new webhook → copy the URL
- **Discord**: server settings → integrations → webhooks → new webhook → copy the URL

## AskUserQuestion constraints

**Key limitation**: AskUserQuestion allows at most 4 options per question (minItems=2, maxItems=4). With 11 channels, they do not fit in a single question.

**How to work around it:**
- For the 6 short-delay channels, use two rounds: round one covers macos/telegram/bark/pushover, round two covers ntfy/gotify (2 options is fine)
- For the 5 fallback channels, use two rounds: round one covers wechat/feishu/dingtalk/slack, round two covers discord (2 options: enable / do not enable)
- Use `multiSelect: true` and mark each description with `[enabled]` or `[disabled]` so the user can tell the current state
- An enabled channel is not disabled just because the user left it unselected — disable it only when the user explicitly deselects it

## Workflow

### Step 1: read the existing configuration

Use Bash to read the configuration file (check `${CLAUDE_PLUGIN_DATA}/notify.json` first, then `~/.claude/hooks/notify.json`). If it does not exist, remember that a new configuration must be created later. Determine each channel's enabled state and whether its credentials are still placeholders.

### Step 2: show the current state

Show the user an overview table of every channel's current state:

```
Short-delay channels (instant reach)
  macos      ✅ enabled    delay 3s
  telegram   ❌ not configured
  bark       ❌ not configured
  pushover   ❌ not configured
  ntfy       ❌ not configured
  gotify     ❌ not configured

Fallback channels (async safety net)
  wechat     ✅ enabled    delay 300s
  feishu     ❌ not configured
  dingtalk   ❌ not configured
  slack      ❌ not configured
  discord    ❌ not configured
```

### Step 3: choose the short-delay channels

**Round one (4 channels)**: use AskUserQuestion (multiSelect=true) to let the user choose which short-delay channels to enable.

Options: macos, telegram, bark, pushover. Mark each option's description with its current state, for example:
- label: "macos", description: "[currently enabled] macOS system notification, zero configuration"
- label: "telegram", description: "[currently disabled] Telegram bot, requires bot_token and chat_id"

**Round two (2 channels)**: ntfy and gotify, again with multiSelect=true and state markers in the descriptions.

Merge the results of both rounds. Compare against the existing configuration:
- Newly selected channels → mark them for configuration
- Deselected channels → set enabled=false (keep the credentials)
- Unchanged channels → leave them alone

### Step 4: choose the fallback channels

Again in rounds:

**Round one**: wechat, feishu, dingtalk, slack (multiSelect=true)
**Round two**: discord (2 options: enable / do not enable)

Merge the results using the same logic as step 3.

### Step 5: configure channel credentials (loop)

For every newly enabled channel, or every channel whose credentials are still placeholders, guide the user one at a time:

1. Show how to obtain that channel's credentials (look them up in "Where to find channel credentials" above)
2. Use AskUserQuestion to request each required field individually. Use the preview to show the expected credential format.
3. Ask about the delay (show the default and offer 2-3 common options plus Other)
4. Optionally ask whether to restrict the event types

Write the configuration file as soon as each channel is configured so nothing is lost.

Then use AskUserQuestion to ask what to do next:
- **Configure the next channel** (if any are still pending)
- **Edit an already configured channel** — let the user pick a configured channel to re-edit
- **Finish configuration**

If the user chooses "Edit an already configured channel", show that channel's current values (masked credentials) and let the user change them field by field (leaving a field empty keeps it unchanged). When the edits are done, return to this step and continue the loop.

If the user chooses "Finish configuration", move on to the next step.

### Step 6: save and test

Write the final configuration to the configuration file.

**Writing rules:**
- If the original configuration came from `~/.claude/hooks/notify.json`, keep writing to that path
- If it is a new configuration, write to `${CLAUDE_PLUGIN_DATA}/notify.json` (run `mkdir -p` with Bash first to make sure the directory exists)
- Keep the JSON formatted (2-space indentation)
- Do not drop channel configurations the user did not modify
- Always include the `rate_limit` field

After writing, use AskUserQuestion to ask whether to test:
- **Test every enabled channel**
- **Test specific channels**
- **Skip testing**

Run the tests with Bash:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/test_notify.sh <channel_name>
```

## Notes

- Use AskUserQuestion for all interaction; never assume the user's choices
- Mask credentials when displaying them (show only the first 4 and last 4 characters, with `***` in between)
- Communicate with the user in English
- Save immediately after every change so nothing is lost along the way
- If `$ARGUMENTS` contains a channel name (such as `/cc-notify-hooks:config bark`), skip the channel selection step and go straight to that channel's credential configuration
- Placeholder detection: a credential value counts as unconfigured when it starts with the `your-` prefix or matches the default value from the example template
