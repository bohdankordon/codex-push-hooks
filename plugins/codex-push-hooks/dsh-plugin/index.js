/**
 * dsh-codex-push-hooks — codex-push-hooks bridge plugin for the DeepSeek Harness (dsh).
 *
 * A zero-dependency host plugin that reuses the codex-push-hooks bash scripts:
 *
 *   approval/request      → notify.sh notification   (approval needed 🔔, always proxies next())
 *   agent/turn-stopping   → notify.sh stop            (task complete ✅)
 *   agent/pre-step        → clear_pending.sh          (cancel queued pushes on user response / /exit marker)
 *   tools/pre-execute     → pre_tool_use.sh           (ask_user_question triggers a waiting-for-reply
 *                                                        notification, other tools clear pending)
 *   tools/post-execute    → clear_pending.sh user_input (clears after the question returns)
 *
 * Configuration (plugin `config:` in ~/.dsh/cordis.patch.yml):
 *   scriptsDir  — absolute path of the codex-push-hooks scripts directory (required)
 *   stateDir    — pending/rate-limit state directory (default ~/.claude/hooks/state,
 *                 shared with the Claude/Codex/Reasonix installs)
 *   configFile  — optional notify.json override (default: notify.sh's own lookup chain)
 */

import { spawn } from 'node:child_process'
import { homedir } from 'node:os'

export const name = 'dsh-codex-push-hooks'

/** dsh question tools that deserve a "waiting for reply" push. */
const QUESTION_TOOLS = new Set(['ask_user_question'])

/**
 * Cordis plugin entry: register listeners on the harness interception points.
 * Every waterfall listener delegates with `next()` — this plugin only
 * observes and pushes notifications, it never blocks or answers a decision.
 */
export function apply(ctx, config = {}) {
  const scriptsDir = typeof config.scriptsDir === 'string' ? config.scriptsDir.trim() : ''
  if (!scriptsDir) {
    ctx.logger.warn(
      '[dsh-codex-push-hooks] scriptsDir is not configured; plugin disabled. '
      + 'Set config.scriptsDir to the codex-push-hooks scripts directory.',
    )
    return
  }

  const stateDir = typeof config.stateDir === 'string' && config.stateDir.trim()
    ? config.stateDir.trim()
    : `${homedir()}/.claude/hooks/state`

  const hookEnv = {
    ...process.env,
    // Tells notify.sh which agent the event comes from (title prefix "dsh ·").
    DSH_CC_NOTIFY: '1',
    CC_NOTIFY_STATE_DIR: stateDir,
  }
  if (typeof config.configFile === 'string' && config.configFile.trim()) {
    hookEnv.CC_NOTIFY_CONFIG = config.configFile.trim()
  }

  /** Spawn one codex-push-hooks script with the hook payload on stdin, detached. */
  function runScript(script, args, payload) {
    let child
    try {
      child = spawn(script, args, {
        env: hookEnv,
        stdio: ['pipe', 'ignore', 'ignore'],
        detached: true,
      })
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] failed to start ${script}: ${String(error)}`)
      return
    }
    child.on('error', (error) => {
      ctx.logger.warn(`[dsh-codex-push-hooks] ${script} failed: ${String(error)}`)
    })
    child.stdin.on('error', () => {})
    child.stdin.end(payload === undefined ? '' : JSON.stringify(payload))
    child.unref()
  }

  const notify = (payload) => runScript(`${scriptsDir}/notify.sh`, ['notification'], payload)
  const notifyStop = (payload) => runScript(`${scriptsDir}/notify.sh`, ['stop'], payload)
  const clear = (payload, args = []) => runScript(`${scriptsDir}/clear_pending.sh`, args, payload)
  const preTool = (payload) => runScript(`${scriptsDir}/pre_tool_use.sh`, [], payload)

  /** CC-shaped base payload: hook_event_name + session identity + cwd. */
  function base(agent, event) {
    const header = agent?.session?.header
    return {
      session_id: typeof header?.id === 'string' ? header.id : '',
      transcript_path: '',
      cwd: typeof header?.cwd === 'string' && header.cwd ? header.cwd : process.cwd(),
      hook_event_name: event,
    }
  }

  function blocksToText(blocks) {
    const list = Array.isArray(blocks) ? blocks : []
    return list
      .filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text)
      .join('')
  }

  // Track the latest assistant text per session so Stop notifications can
  // carry a useful summary (the turn-stopping payload has no message).
  const lastAssistantText = new Map()
  ctx.on('session/event', (session, event) => {
    try {
      if (event?.type !== 'assistant/message') return
      const text = blocksToText(event.data?.message?.content)
      if (text) lastAssistantText.set(session.id, text)
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] session observer failed: ${String(error)}`)
    }
  })

  // Pending approval → "approval needed" push. Always delegate: never answer.
  ctx.on('approval/request', (request, next) => {
    try {
      notify({
        ...base(request?.agent, 'Notification'),
        notification_type: 'permission_prompt',
        message: typeof request?.reason === 'string' && request.reason
          ? request.reason
          : `approval requested for ${request?.toolName ?? 'tool'}`,
        tool_name: typeof request?.toolName === 'string' ? request.toolName : '',
      })
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] approval notification failed: ${String(error)}`)
    }
    return next()
  })

  // Natural turn end → "task complete" push.
  ctx.on('agent/turn-stopping', (payload) => {
    try {
      const agent = payload?.agent
      const sessionId = typeof agent?.session?.header?.id === 'string' ? agent.session.header.id : ''
      const text = sessionId ? lastAssistantText.get(sessionId) : undefined
      if (sessionId) lastAssistantText.delete(sessionId)
      notifyStop({
        ...base(agent, 'Stop'),
        stop_hook_active: false,
        last_assistant_message: typeof text === 'string' ? text : '',
      })
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] stop notification failed: ${String(error)}`)
    }
  })

  // User prompt submitted → cancel queued pushes (and mark /exit).
  ctx.on('agent/pre-step', async (payload, next) => {
    try {
      const agent = payload?.agent
      const text = blocksToText((payload?.messages ?? []).flatMap((message) => message.content ?? []))
      clear({
        ...base(agent, 'UserPromptSubmit'),
        prompt: text,
      })
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] pre-step clear failed: ${String(error)}`)
    }
    return next()
  })

  // Tool about to run: questions trigger a "waiting for reply" push, other
  // tools cancel queued pushes. Never blocks the tool call.
  ctx.on('tools/pre-execute', (exec, next) => {
    try {
      const agent = exec?.agent
      const toolName = typeof exec?.name === 'string' ? exec.name : ''
      const payload = {
        ...base(agent, 'PreToolUse'),
        tool_name: QUESTION_TOOLS.has(toolName) ? 'request_user_input' : toolName,
        tool_input: exec?.arguments ?? {},
        tool_use_id: typeof exec?.callId === 'string' ? exec.callId : '',
      }
      preTool(payload)
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] pre-tool dispatch failed: ${String(error)}`)
    }
    return next()
  })

  // Question tool returned → clear the user_input pending marker.
  ctx.on('tools/post-execute', (exec, _result, next) => {
    try {
      if (QUESTION_TOOLS.has(exec?.name)) {
        clear({
          ...base(exec?.agent, 'PostToolUse'),
          tool_name: 'request_user_input',
          tool_use_id: typeof exec?.callId === 'string' ? exec.callId : '',
        }, ['user_input'])
      }
    } catch (error) {
      ctx.logger.warn(`[dsh-codex-push-hooks] post-tool clear failed: ${String(error)}`)
    }
    return next()
  })

  ctx.logger.info(`[dsh-codex-push-hooks] active (scriptsDir=${scriptsDir}, stateDir=${stateDir})`)
}
