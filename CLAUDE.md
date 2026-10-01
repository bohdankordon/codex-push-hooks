# codex-push-hooks

Tiered push notifications for Claude Code, Codex CLI, Reasonix, and dsh (DeepSeek Harness). Notifications are triggered through hooks/interception points, and queued pushes are cancelled automatically once the user responds.

## Tech stack

- **Languages**: Bash (core scripts) + JavaScript (dsh host plugin, zero dependencies)
- **Dependencies**: `jq` (JSON parsing), `curl` (HTTP requests), `osascript` (macOS notifications)
- **Integrations**: the hook/plugin mechanisms of Claude Code / Codex CLI / Reasonix, plus dsh's cordis interception points

## Project structure

```
plugins/codex-push-hooks/    # the real plugin root (the scripts/hooks/config entries at the repository root are symlinks)
├── scripts/notify.sh       # main dispatcher: event filtering, delayed queueing, channel fan-out (compatible with all 4 agents' fields)
├── scripts/clear_pending.sh# clear pending notifications (triggered on user interaction)
├── scripts/pre_tool_use.sh # question-tool dispatcher (request_user_input / ask / AskUserQuestion)
├── scripts/channels/*.sh   # 11 channel implementations
├── scripts/windows/        # native Windows runtime: hook.ps1 (entry), worker.ps1 (detached delivery), CodexPushHooks.psm1 (shared logic; no Bash/jq/curl/WSL)
├── hooks/hooks.json        # Claude Code hook event definitions
├── hooks/codex-hooks.json  # Codex CLI hook event definitions
├── reasonix-plugin.json    # native Reasonix plugin manifest (v2, payloadFormat=claude)
├── dsh-plugin/             # dsh host plugin (cordis, subscribes to 5 interception points)
├── .claude-plugin/         # Claude Code plugin manifest
├── .codex-plugin/          # Codex CLI plugin manifest
├── config/notify.example.json
└── skills/config/SKILL.md  # interactive configuration skill (Claude Code only)
install.sh                  # standalone installer entry point (router)
install/{claude,codex,reasonix,dsh}.sh
install/codex.ps1            # native Windows Codex installer (PowerShell, custom CODEX_HOME, hooks.json merge)
test_notify.sh              # channel connectivity + template/agent detection tests
```

## Common commands

```bash
# Install
bash install.sh                  # interactively choose Claude Code / Codex / Reasonix / dsh
bash install.sh claude|codex|reasonix|dsh

# Test
bash test_notify.sh              # test every enabled channel
bash test_notify.sh bark         # test a single channel
bash test_notify.sh hook         # simulate the Claude Code hook flow
bash test_notify.sh codex        # simulate a Codex CLI PermissionRequest event
bash test_notify.sh agents       # verify Reasonix / dsh agent detection
node plugins/codex-push-hooks/dsh-plugin/test/plugin.test.mjs  # dsh plugin unit tests

# Run in plugin mode
claude --plugin-dir ./codex-push-hooks
reasonix plugin install ./plugins/codex-push-hooks --link --yes
```

## Core mechanics

- **Tiered delays**: short-delay notifications (seconds: macOS/Bark/Telegram) → fallback notifications (minutes: WeCom/Feishu/DingTalk/Slack)
- **Pending cancellation**: a marker file is created before sending and removed when the user responds; the background process checks the marker to decide whether to send
- **Rate limiting**: by default the same event category is not pushed again within 10 seconds
- **Event filtering**: skip subagents, Stop-loop protection, /exit silence

## Configuration

Configuration file lookup order (implemented in `scripts/notify.sh`):
1. `${CC_NOTIFY_CONFIG}` (manual override)
2. `${PLUGIN_DATA}/notify.json` (Codex plugin mode), `${CLAUDE_PLUGIN_DATA}/notify.json` (Claude plugin mode)
3. `~/.codex/codex-push-hooks/notify.json` (Codex standalone mode)
4. `~/.reasonix/codex-push-hooks/notify.json` (Reasonix; `REASONIX_HOME` can override the base directory)
5. `~/.dsh/codex-push-hooks/notify.json` (dsh; `DSH_HOME` can override the base directory)
6. `~/.codex/cc-notify-hooks/notify.json` (legacy pre-rebrand fallback)
7. `~/.reasonix/cc-notify-hooks/notify.json` (legacy pre-rebrand fallback)
8. `~/.dsh/cc-notify-hooks/notify.json` (legacy pre-rebrand fallback)
9. `~/.claude/hooks/notify.json` (Claude standalone mode)

Every canonical path (3-5) takes precedence over every legacy path (6-8),
so a legacy file can never shadow a canonical configuration from another
agent; the explicit `CC_NOTIFY_CONFIG` override wins over everything. The
standalone installers offer to reuse a legacy configuration on first install
(copied, never moved or deleted). `test_notify.sh config-paths` covers
discovery, fallback, and precedence; `test_notify.sh install-smoke` covers
the installer behavior.

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

## Development notes

- Every channel script follows the same interface: `$1` is the title, `$2` is the body, and credentials come from environment variables or the configuration file
- Channel sends are wrapped in `|| true`, so a single failure does not affect the other channels
- Without a configuration file, macOS users automatically fall back to system notifications

## Development conventions

### Plugin development

**Claude Code**:
- Manifest: `.claude-plugin/plugin.json`; hook configuration: `hooks/hooks.json`
- Path references use `${CLAUDE_PLUGIN_ROOT}` (plugin root) and `${CLAUDE_PLUGIN_DATA}` (persistent data)
- After changing the plugin, validate with `claude plugin validate .` and test locally with `claude --plugin-dir .`
- When driving skill interactions, mind the AskUserQuestion limit: 2-4 options per question

**Codex CLI**:
- Manifest: `.codex-plugin/plugin.json`; hook configuration: `hooks/codex-hooks.json`
- Codex hook commands run from the session `cwd`, so `./scripts/...` does not work; in plugin mode the scripts must be located from `~/.codex/plugins/cache/*/codex-push-hooks/*/`
- Marketplace: `.agents/plugins/marketplace.json`; the `policy` block requires `installation`/`authentication`/`category`
- Enabling hooks requires `[features]` with `codex_hooks = true` in `~/.codex/config.toml`
- Field differences: Codex uses `prompt` where Claude uses `message` (the scripts already fall back between them), and Codex has no Notification event (PermissionRequest takes its place)

**Reasonix**:
- Manifest: `reasonix-plugin.json` (`reasonix.io/plugin/v2`, parsed strictly: unknown fields such as author/license/keywords are not allowed)
- Hooks use exec form (`command: "bash"` + `args`) plus `payloadFormat: "claude"` — the exec+claude combination is exempt from plugin-root path joining, which is how the scripts receive Claude-shaped stdin (`hook_event_name`/`session_id`/`message`/`notification_type`…)
- Reasonix supports 11 events: PreToolUse/PostToolUse/UserPromptSubmit/Stop/Notification/SessionStart/SessionEnd/SubagentStop/PreCompact/PostLLMCall/PermissionRequest
- Waiting for approval fires `Notification` (`notification_type=permission_prompt`), and the question tool is called `ask` (Claude calls it `AskUserQuestion`; the input schema is compatible with the parsing in notify.sh)
- Install/verify: `reasonix plugin install <dir> --dry-run` (check compatibility) → `--link --yes` → `reasonix hook list --json` / `reasonix doctor capabilities --json`
- Native hook stdin uses the `event`/`sessionId`/`lastAssistantText` fields (the scripts already handle them as a fallback); only the plugin import format carries `hook_event_name`
- Hooks are loaded when a session is built: restart the session after changing the configuration; `/new` does not reload them

**dsh (DeepSeek Harness)**:
- Host plugin in `dsh-plugin/` (cordis: `export const name` + `export function apply(ctx, config)`, zero dependencies and only Node built-ins)
- Subscribed interception points: `approval/request` (waterfall — after observing, it must proxy with `next()`), `agent/turn-stopping` (serial, payload carries the injected `agent`), `agent/pre-step`, `tools/pre-execute` (`exec.name/arguments/callId/agent`), `tools/post-execute`, `session/event` (tracks the `assistant/message` summary)
- The question tool is called `ask_user_question`; when forwarding, the plugin rewrites it to `request_user_input` so it reuses the parsing in pre_tool_use.sh
- Installation (same as dsh-feishu): symlink into `~/node_modules/@dsh-local/codex-push-hooks` + append an insert entry to `~/.dsh/cordis.patch.yml` (`name: '@dsh-local/codex-push-hooks'`)
- dsh hot-loads the home-level `~/.dsh/cordis.patch.yml` (`watchUserPatches`), so running sessions need no restart; `dsh web --dump-config` verifies the composition tree
- Plugin tests: `node plugins/codex-push-hooks/dsh-plugin/test/plugin.test.mjs` (stub scripts capture spawns, a mock ctx drives the events)

**Shared across agents**:
- Channel script interface: `$1` is the title, `$2` is the body, credentials come from environment variables or the configuration file
- Channel sends are wrapped in `|| true`, so a single failure does not affect the other channels
- Agent detection (notify.sh): `CC_NOTIFY_AGENT` override → `REASONIX_PLUGIN_ROOT` (Reasonix) → `DSH_CC_NOTIFY` (dsh) → Notification/`.claude` path (Claude Code) → Codex by default
- The state directory defaults to the shared `~/.claude/hooks/state`, isolated per session

### Versioning and release

- Version numbers follow semantic versioning (MAJOR.MINOR.PATCH)
- Before bumping a version you must confirm the target version with the user; never decide it on your own
- Keep the version in sync across six manifests: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json`, `plugins/codex-push-hooks/reasonix-plugin.json`, `plugins/codex-push-hooks/dsh-plugin/package.json`
- Feature changes must be reflected in the README and in `docs/index.html` (GitHub Pages)
- Release flow: commit → push → `gh release create vX.Y.Z`

### README maintenance

- New features must update the corresponding README sections (configuration, file structure, and so on)
- Users do not necessarily need to restart Claude Code; `/reload-plugins` is enough to refresh the plugin

## References

- [Claude Code plugin development guide](https://code.claude.com/docs/en/plugins.md)
- [Claude Code plugin reference](https://code.claude.com/docs/en/plugins-reference.md)
- [Codex hooks documentation](https://developers.openai.com/codex/hooks)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [Reasonix plugin package documentation](https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/docs/PLUGIN_PACKAGES.md)
- [Reasonix Desktop hooks documentation](https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/docs/DESKTOP_HOOKS.zh-CN.md)
- dsh interception points Agent Note: `~/.dsh/source/current/.agents/notes/implemented/feature/2026-06-30-interception-extension-points.md`
- dsh approval seam Agent Note: `~/.dsh/source/current/.agents/notes/implemented/feature/2026-07-06-approval-seam.md`
