# hook.ps1 - thin Codex lifecycle-hook entry point (native Windows).
# Reads one JSON hook event from stdin, selects the action, exits quickly.
# Notification delivery is delegated to a detached worker.ps1 process so
# long fallback delays never keep the hook alive. Failures never block Codex.
#
# Actions (mirror the POSIX scripts):
#   notification [kind]  - notify path (PermissionRequest; pre-tool-use user_input)
#   stop                 - notify path (Stop)
#   clear [kind]         - clear pending for the current session (UserPromptSubmit; PostToolUse)
#   pre-tool-use         - dispatcher (request_user_input/request_user_input_async/ask/AskUserQuestion or clear)
param([string]$Action = '', [string]$KindArg = '')

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'CodexPushHooks.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function Read-StdInText {
    try {
        if ([Console]::IsInputRedirected) { return [Console]::In.ReadToEnd() }
    } catch { }
    return ''
}

function Invoke-NotifyFlow {
    param([string]$RawInput, [string]$EventType, [string]$EventKind)
    $evt = ConvertFrom-CphHookJson -RawJson $RawInput
    if ($null -eq $evt) { return }
    if ($env:CC_NOTIFY_RENDER_ONLY -eq '1') {
        $preview = Get-CphNotificationContent -Event $evt -EventType $EventType -EventKind $EventKind
        $preview['EventObject'] | ConvertTo-Json -Depth 20 | Write-Output
        return
    }
    $configPath = Find-CphNotifyConfig
    if ([string]::IsNullOrEmpty($configPath)) { return }
    $rateLimit = Get-CphRateLimit -ConfigPath $configPath
    $stateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
    if ([string]::IsNullOrEmpty($stateDir)) { return }
    $filter = Test-CphNotifyFilter -Event $evt -EventType $EventType -EventKind $EventKind -StateDir $stateDir -RateLimit $rateLimit
    if ($filter['Skip']) { return }
    $content = Get-CphNotificationContent -Event $evt -EventType $EventType -EventKind $EventKind
    $scope = Get-CphSessionScope -Event $evt
    $sessionKey = ConvertTo-CphSafeKey -Value $scope
    $kindKey = ConvertTo-CphSafeKey -Value $content['EventKind']
    $toolKey = ConvertTo-CphSafeKey -Value $evt['ToolUseId']
    if ([string]::IsNullOrEmpty($evt['ToolUseId'])) { $toolKey = 'no-call' }
    # While an async question waits for its answer, a different notification kind
    # must not delete the live Reply-needed delivery pending.
    $preserveKind = ''
    if ($content['EventKind'] -ne 'user_input' -and (Test-CphAsyncAwaiting -StateDir $stateDir -SessionKey $sessionKey)) { $preserveKind = 'user_input' }
    $pendingFile = New-CphPendingFile -StateDir $stateDir -SessionKey $sessionKey -KindKey $kindKey -ToolUseKey $toolKey -EventKind $content['EventKind'] -PreserveKind $preserveKind
    if ([string]::IsNullOrEmpty($pendingFile)) { return }
    $queue = @(Build-CphSendQueue -ConfigPath $configPath -EventType $EventType)
    if ($null -eq $queue -or $queue.Count -eq 0) { return }
    $job = @{
        configPath = $configPath
        eventType = $EventType
        eventKind = $content['EventKind']
        title = $content['Title']
        body = $content['Body']
        content = $content
        pendingFile = $pendingFile
        queue = $queue
        stateDir = $stateDir
    }
    $jobPath = New-CphJobFile -StateDir $stateDir -Job $job
    if ([string]::IsNullOrEmpty($jobPath)) { return }
    try {
        $worker = Join-Path $PSScriptRoot 'worker.ps1'
        $argLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $worker + '" -JobPath "' + $jobPath + '"'
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden
        if ($content['EventKind'] -eq 'user_input' -and $evt['ToolName'] -eq 'request_user_input_async') {
            # The delivery is scheduled, so the session is now durably waiting for
            # the user's answer. This survives the tool completion, unrelated tool
            # calls, Stop, and the delivery itself; UserPromptSubmit ends it.
            [void](Set-CphAsyncAwaiting -StateDir $stateDir -SessionKey $sessionKey -ToolUseKey $evt['ToolUseId'])
        }
    } catch {
        # The worker never started, so nothing will ever consume this delivery:
        # remove exactly the job file and pending marker this invocation created
        # (other sessions' state is never touched). Stay fail-open for Codex.
        try { if (Test-Path -LiteralPath $jobPath) { Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $pendingFile) { Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Invoke-ClearFlow {
    param([string]$RawInput, [string]$KindFilter, [string]$PreserveKind = '')
    $evt = ConvertFrom-CphHookJson -RawJson $RawInput
    if ($null -eq $evt) { return }
    $stateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
    if ([string]::IsNullOrEmpty($stateDir)) { return }
    Clear-CphPendingFromEvent -Event $evt -StateDir $stateDir -KindFilter $KindFilter -PreserveKind $PreserveKind
}

try {
    $raw = Read-StdInText
    $a = ''
    if ($Action -ne '') { $a = $Action.ToLowerInvariant() }
    switch ($a) {
        'notification' {
            Invoke-NotifyFlow -RawInput $raw -EventType 'notification' -EventKind $KindArg
        }
        'stop' {
            $stopEvent = ConvertFrom-CphHookJson -RawJson $raw
            if ($null -ne $stopEvent) {
                $stopStateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
                if (-not [string]::IsNullOrEmpty($stopStateDir)) {
                    $stopSessionKey = ConvertTo-CphSafeKey -Value (Get-CphSessionScope -Event $stopEvent)
                    if (Test-CphAsyncAwaiting -StateDir $stopStateDir -SessionKey $stopSessionKey) {
                        # An async question is on screen and unanswered: this Stop is not
                        # task completion (the runtime ends the turn while the question
                        # waits), so skip the Stop notification entirely -- no pending,
                        # no job, and no Stop rate-limit state.
                        break
                    }
                }
            }
            Invoke-NotifyFlow -RawInput $raw -EventType 'stop' -EventKind 'stop'
        }
        'clear' {
            $clearEvent = ConvertFrom-CphHookJson -RawJson $raw
            if ($null -ne $clearEvent -and $clearEvent['HookEvent'] -eq 'UserPromptSubmit') {
                $clearStateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
                if (-not [string]::IsNullOrEmpty($clearStateDir)) {
                    $clearSessionKey = ConvertTo-CphSafeKey -Value (Get-CphSessionScope -Event $clearEvent)
                    # The answer to an async question arrives as user input, so
                    # UserPromptSubmit is the authoritative end of async waiting.
                    Clear-CphAsyncAwaiting -StateDir $clearStateDir -SessionKey $clearSessionKey
                }
            }
            Invoke-ClearFlow -RawInput $raw -KindFilter $KindArg
        }
        'pre-tool-use' {
            $pe = ConvertFrom-CphHookJson -RawJson $raw
            if ($null -eq $pe) { break }
            $tn = $pe['ToolName']
            # POSIX parity (pre_tool_use.sh): a question tool with no questions
            # neither notifies nor clears; every other tool clears pending state.
            # request_user_input_async is the current async question tool. Its
            # completion is not the user's answer, so the PostToolUse manifest
            # matcher deliberately does not cover it; the later UserPromptSubmit
            # clears the pending notification instead.
            $questionTools = @('request_user_input', 'request_user_input_async', 'ask', 'AskUserQuestion')
            if ($questionTools -contains $tn) {
                $notify = ([int]$pe['QuestionCount'] -gt 0)
                if ($tn -eq 'request_user_input_async' -and -not [bool]$pe['AsyncQuestionPayloadValid']) {
                    # Codex validates the async tool's arguments only after PreToolUse
                    # runs, so a payload the handler will reject must stay quiet: no
                    # notification (the user never sees the question) and no clear
                    # (the tool is still recognized, so it must not fall through to
                    # the ordinary-tool clear behavior).
                    $notify = $false
                }
                if ($tn -ne 'request_user_input_async') {
                    # A new synchronous question supersedes an outstanding async wait;
                    # without this a stale marker could keep suppressing Stop after
                    # the synchronous question has been answered and cleared.
                    $syncStateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
                    if (-not [string]::IsNullOrEmpty($syncStateDir)) {
                        $syncSessionKey = ConvertTo-CphSafeKey -Value (Get-CphSessionScope -Event $pe)
                        Clear-CphAsyncAwaiting -StateDir $syncStateDir -SessionKey $syncSessionKey
                    }
                }
                if ($notify) {
                    Invoke-NotifyFlow -RawInput $raw -EventType 'notification' -EventKind 'user_input'
                }
            } else {
                # Ordinary tool activity while an async question waits is not a user
                # answer: the Reply-needed delivery pending must survive any tool.
                $preserve = ''
                $toolStateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
                if (-not [string]::IsNullOrEmpty($toolStateDir)) {
                    $toolSessionKey = ConvertTo-CphSafeKey -Value (Get-CphSessionScope -Event $pe)
                    if (Test-CphAsyncAwaiting -StateDir $toolStateDir -SessionKey $toolSessionKey) { $preserve = 'user_input' }
                }
                Invoke-ClearFlow -RawInput $raw -KindFilter '' -PreserveKind $preserve
            }
        }
        default { }
    }
} catch { }
exit 0
