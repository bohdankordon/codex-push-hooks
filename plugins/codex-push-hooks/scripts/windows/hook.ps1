# hook.ps1 - thin Codex lifecycle-hook entry point (native Windows).
# Reads one JSON hook event from stdin, selects the action, exits quickly.
# Notification delivery is delegated to a detached worker.ps1 process so
# long fallback delays never keep the hook alive. Failures never block Codex.
#
# Actions (mirror the POSIX scripts):
#   notification [kind]  - notify path (PermissionRequest; pre-tool-use user_input)
#   stop                 - notify path (Stop)
#   clear [kind]         - clear pending for the current session (UserPromptSubmit; PostToolUse)
#   pre-tool-use         - dispatcher (request_user_input/ask/AskUserQuestion or clear)
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
    $pendingFile = New-CphPendingFile -StateDir $stateDir -SessionKey $sessionKey -KindKey $kindKey -ToolUseKey $toolKey -EventKind $content['EventKind']
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
    } catch {
        # The worker never started, so nothing will ever consume this delivery:
        # remove exactly the job file and pending marker this invocation created
        # (other sessions' state is never touched). Stay fail-open for Codex.
        try { if (Test-Path -LiteralPath $jobPath) { Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $pendingFile) { Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Invoke-ClearFlow {
    param([string]$RawInput, [string]$KindFilter)
    $evt = ConvertFrom-CphHookJson -RawJson $RawInput
    if ($null -eq $evt) { return }
    $stateDir = Ensure-CphStateDirectory -StateDir (Get-CphStateDirectory)
    if ([string]::IsNullOrEmpty($stateDir)) { return }
    Clear-CphPendingFromEvent -Event $evt -StateDir $stateDir -KindFilter $KindFilter
}

try {
    $raw = Read-StdInText
    $a = ''
    if ($Action -ne '') { $a = $Action.ToLowerInvariant() }
    switch ($a) {
        'notification' {
            Invoke-NotifyFlow -RawInput $raw -EventType 'notification' -EventKind $KindArg
        }
        'stop' { Invoke-NotifyFlow -RawInput $raw -EventType 'stop' -EventKind 'stop' }
        'clear' { Invoke-ClearFlow -RawInput $raw -KindFilter $KindArg }
        'pre-tool-use' {
            $pe = ConvertFrom-CphHookJson -RawJson $raw
            if ($null -eq $pe) { break }
            $tn = $pe['ToolName']
            # POSIX parity (pre_tool_use.sh): a question tool with no questions
            # neither notifies nor clears; every other tool clears pending state.
            if ($tn -eq 'request_user_input' -or $tn -eq 'ask' -or $tn -eq 'AskUserQuestion') {
                if ([int]$pe['QuestionCount'] -gt 0) {
                    Invoke-NotifyFlow -RawInput $raw -EventType 'notification' -EventKind 'user_input'
                }
            } else {
                Invoke-ClearFlow -RawInput $raw -KindFilter ''
            }
        }
        default { }
    }
} catch { }
exit 0
