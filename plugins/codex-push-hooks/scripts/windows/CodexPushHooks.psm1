# CodexPushHooks - shared native Windows runtime (Windows PowerShell 5.1).
# Parity port of scripts/notify.sh, scripts/clear_pending.sh,
# scripts/pre_tool_use.sh and scripts/lib/notify_format.sh.
# No Bash, no jq, no curl.exe, no WSL.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region Home, config and state locations

function Get-CphHomeDirectory {
    if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE)) { return $env:USERPROFILE }
    if ($env:HOME -and (Test-Path -LiteralPath $env:HOME)) { return $env:HOME }
    try {
        $p = [Environment]::GetFolderPath('UserProfile')
        if ($p) { return $p }
    } catch { }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    return ''
}

function Get-CphCodexHome {
    if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim() -ne '') { return $env:CODEX_HOME }
    $h = Get-CphHomeDirectory
    if ([string]::IsNullOrEmpty($h)) { return '' }
    return (Join-Path $h '.codex')
}

function Get-CphReasonixHome {
    if ($env:REASONIX_HOME -and $env:REASONIX_HOME.Trim() -ne '') { return $env:REASONIX_HOME }
    $h = Get-CphHomeDirectory
    if ([string]::IsNullOrEmpty($h)) { return '' }
    return (Join-Path $h '.reasonix')
}

function Get-CphDshHome {
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim() -ne '') { return $env:DSH_HOME }
    $h = Get-CphHomeDirectory
    if ([string]::IsNullOrEmpty($h)) { return '' }
    return (Join-Path $h '.dsh')
}

function Find-CphNotifyConfig {
    if ($env:CC_NOTIFY_CONFIG -and (Test-Path -LiteralPath $env:CC_NOTIFY_CONFIG -PathType Leaf)) {
        return $env:CC_NOTIFY_CONFIG
    }
    if ($env:PLUGIN_DATA) {
        $p = Join-Path $env:PLUGIN_DATA 'notify.json'
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    if ($env:CLAUDE_PLUGIN_DATA) {
        $p = Join-Path $env:CLAUDE_PLUGIN_DATA 'notify.json'
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $codexHome = Get-CphCodexHome
    $reasonixHome = Get-CphReasonixHome
    $dshHome = Get-CphDshHome
    $homeDir = Get-CphHomeDirectory
    $candidates = @()
    if ($codexHome) { $candidates += (Join-Path (Join-Path $codexHome 'codex-push-hooks') 'notify.json') }
    if ($reasonixHome) { $candidates += (Join-Path (Join-Path $reasonixHome 'codex-push-hooks') 'notify.json') }
    if ($dshHome) { $candidates += (Join-Path (Join-Path $dshHome 'codex-push-hooks') 'notify.json') }
    if ($codexHome) { $candidates += (Join-Path (Join-Path $codexHome 'cc-notify-hooks') 'notify.json') }
    if ($reasonixHome) { $candidates += (Join-Path (Join-Path $reasonixHome 'cc-notify-hooks') 'notify.json') }
    if ($dshHome) { $candidates += (Join-Path (Join-Path $dshHome 'cc-notify-hooks') 'notify.json') }
    if ($homeDir) { $candidates += (Join-Path (Join-Path (Join-Path $homeDir '.claude') 'hooks') 'notify.json') }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Get-CphStateDirectory {
    if ($env:CC_NOTIFY_STATE_DIR -and $env:CC_NOTIFY_STATE_DIR.Trim() -ne '') { return $env:CC_NOTIFY_STATE_DIR }
    if ($env:PLUGIN_DATA -and $env:PLUGIN_DATA.Trim() -ne '') { return (Join-Path $env:PLUGIN_DATA 'state') }
    if ($env:CLAUDE_PLUGIN_DATA -and $env:CLAUDE_PLUGIN_DATA.Trim() -ne '') { return (Join-Path $env:CLAUDE_PLUGIN_DATA 'state') }
    $codexHome = Get-CphCodexHome
    if ($codexHome -and $codexHome.Trim() -ne '') { return (Join-Path (Join-Path $codexHome 'codex-push-hooks') 'state') }
    $h = Get-CphHomeDirectory
    if ($h) { return (Join-Path (Join-Path $h '.codex-push-hooks') 'state') }
    return ''
}

function Ensure-CphStateDirectory {
    param([string]$StateDir)
    if ([string]::IsNullOrEmpty($StateDir)) { return '' }
    try { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null } catch { }
    return $StateDir
}

#endregion

#region JSON helpers (PS 5.1 safe)

function Get-CphRawField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) { return $prop.Value }
    } catch { }
    return $null
}

function Get-CphStringField {
    param($Object, [string[]]$Names)
    foreach ($n in $Names) {
        $v = Get-CphRawField -Object $Object -Name $n
        if ($v -is [string] -and $v -ne '') { return $v }
    }
    return ''
}

function Read-CphJsonObject {
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    $t = $Raw.Trim()
    if ($t -eq '') { return $null }
    try {
        $o = $t | ConvertFrom-Json
        return $o
    } catch { return $null }
}

function Read-CphJsonFile {
    param([string]$Path)
    try {
        if ([string]::IsNullOrEmpty($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        return (Read-CphJsonObject -Raw $raw)
    } catch { return $null }
}

function ConvertTo-CphArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
}

#endregion

#region Normalization

function ConvertTo-CphSafeKey {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'unknown' }
    $s = [System.Text.RegularExpressions.Regex]::Replace($Value, '[^A-Za-z0-9_.-]', '_')
    if ($s.Length -gt 96) { $s = $s.Substring(0, 96) }
    if ([string]::IsNullOrEmpty($s)) { return 'unknown' }
    return $s
}

function ConvertFrom-CphHookJson {
    param([string]$RawJson)
    $obj = Read-CphJsonObject -Raw $RawJson
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Array]) { return $null }
    if ($obj -is [string]) { return $null }
    if ($obj -is [ValueType]) { return $null }
    $hookEvent = Get-CphStringField -Object $obj -Names @('hook_event_name', 'event')
    $message = Get-CphStringField -Object $obj -Names @('message', 'prompt')
    $cwd = Get-CphStringField -Object $obj -Names @('cwd')
    $sessionId = Get-CphStringField -Object $obj -Names @('session_id', 'sessionId')
    $turnId = Get-CphStringField -Object $obj -Names @('turn_id', 'turnId')
    $toolUseId = Get-CphStringField -Object $obj -Names @('tool_use_id', 'toolUseId')
    $transcript = Get-CphStringField -Object $obj -Names @('transcript_path', 'transcriptPath')
    $permMode = Get-CphStringField -Object $obj -Names @('permission_mode', 'permissionMode')
    $agentId = Get-CphStringField -Object $obj -Names @('agent_id', 'agentId')
    $notifType = Get-CphStringField -Object $obj -Names @('notification_type', 'notificationType')
    $model = Get-CphStringField -Object $obj -Names @('model')
    $lastAssistant = Get-CphStringField -Object $obj -Names @('last_assistant_message', 'lastAssistantText')
    $toolName = ''
    $tn = Get-CphRawField -Object $obj -Name 'tool_name'
    if ($tn -is [string] -and $tn -ne '') { $toolName = $tn }
    else {
        $toolObj = Get-CphRawField -Object $obj -Name 'tool'
        if ($toolObj -is [string] -and $toolObj -ne '') { $toolName = $toolObj }
        elseif ($null -ne $toolObj) {
            $nested = Get-CphStringField -Object $toolObj -Names @('name')
            if ($nested -ne '') { $toolName = $nested }
        }
    }
    $stopActive = $false
    try {
        $sv = Get-CphRawField -Object $obj -Name 'stop_hook_active'
        if ($sv -eq $true) { $stopActive = $true }
        elseif ($sv -is [string] -and $sv.ToLower() -eq 'true') { $stopActive = $true }
    } catch { }
    $qCount = 0
    $qHeader = ''
    $qText = ''
    $optLabels = @()
    try {
        $toolInput = Get-CphRawField -Object $obj -Name 'tool_input'
        if ($null -eq $toolInput) { $toolInput = Get-CphRawField -Object $obj -Name 'toolInput' }
        if ($null -ne $toolInput) {
            $qs = @(ConvertTo-CphArray -Value (Get-CphRawField -Object $toolInput -Name 'questions'))
            if ($qs.Count -gt 0) {
                $qCount = $qs.Count
                if ($qCount -gt 0 -and $null -ne $qs[0]) {
                    # Synchronous question schema: header + question.
                    # Async request_user_input_async schema: title only.
                    $qHeader = Get-CphStringField -Object $qs[0] -Names @('header', 'title')
                    $qText = Get-CphStringField -Object $qs[0] -Names @('question', 'title')
                    $opts = @(ConvertTo-CphArray -Value (Get-CphRawField -Object $qs[0] -Name 'options'))
                    if ($opts.Count -gt 0) {
                        foreach ($o in $opts) {
                            if ($null -eq $o) { continue }
                            $lab = ''
                            if ($o -is [string]) { $lab = $o }
                            else { $lab = Get-CphStringField -Object $o -Names @('label') }
                            if ($lab -ne '') { $optLabels += $lab }
                        }
                    }
                }
            }
        }
    } catch { }
    return @{
        HookEvent = $hookEvent
        Message = $message
        Cwd = $cwd
        SessionId = $sessionId
        TurnId = $turnId
        ToolUseId = $toolUseId
        TranscriptPath = $transcript
        PermissionMode = $permMode
        AgentId = $agentId
        NotificationType = $notifType
        Model = $model
        ToolName = $toolName
        LastAssistantMessage = $lastAssistant
        StopHookActive = $stopActive
        QuestionCount = [int]$qCount
        QuestionHeader = $qHeader
        QuestionText = $qText
        OptionLabels = $optLabels
    }
}

function Get-CphAgentName {
    param([hashtable]$Event)
    if ($env:CC_NOTIFY_AGENT -and $env:CC_NOTIFY_AGENT.Trim() -ne '') { return $env:CC_NOTIFY_AGENT }
    if ($env:REASONIX_PLUGIN_ROOT -and $env:REASONIX_PLUGIN_ROOT.Trim() -ne '') { return 'Reasonix' }
    if ($env:DSH_CC_NOTIFY -and $env:DSH_CC_NOTIFY.Trim() -ne '') { return 'dsh' }
    if ($Event['HookEvent'] -eq 'Notification') { return 'Claude Code' }
    $tp = $Event['TranscriptPath']
    if ($tp -and $tp.Contains('.claude')) { return 'Claude Code' }
    return 'Codex'
}

function Get-CphFirstLine {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $lines = $Text -split "`r?`n"
    foreach ($l in $lines) {
        if ($l -match '\S') { return $l }
    }
    return ''
}

function Compress-CphWhitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = [System.Text.RegularExpressions.Regex]::Replace($Text, '\s+', ' ')
    return $s.Trim()
}

function Truncate-CphText {
    param([string]$Text, [int]$MaxLen = 120)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -le $MaxLen) { return $Text }
    if ($MaxLen -le 3) { return $Text.Substring(0, $MaxLen) }
    return ($Text.Substring(0, $MaxLen - 3) + '...')
}

function Get-CphShortSessionId {
    param([string]$Session)
    if ([string]::IsNullOrEmpty($Session)) { return '' }
    if ($Session.Length -le 8) { return $Session }
    return $Session.Substring(0, 8)
}

function Get-CphProjectName {
    param([string]$Cwd)
    if ([string]::IsNullOrEmpty($Cwd)) { return 'unknown' }
    $t = $Cwd.TrimEnd('/', '\')
    if ([string]::IsNullOrEmpty($t)) { return 'unknown' }
    $parts = $t -split '[/\\\\]'
    for ($i = $parts.Length - 1; $i -ge 0; $i--) {
        if ($parts[$i] -ne '') { return $parts[$i] }
    }
    return 'unknown'
}

function Get-CphSessionScope {
    param([hashtable]$Event)
    if ($Event['SessionId'] -ne '') { return $Event['SessionId'] }
    if ($Event['TurnId'] -ne '') { return $Event['TurnId'] }
    return 'unknown'
}

#endregion

#region Notification content (parity with notify.sh)

function Get-CphNotificationContent {
    param([hashtable]$Event, [string]$EventType = 'unknown', [string]$EventKind = '')
    if ([string]::IsNullOrEmpty($EventKind)) { $EventKind = $EventType }
    $agent = Get-CphAgentName -Event $Event
    $project = Get-CphProjectName -Cwd $Event['Cwd']
    $sessionScope = Get-CphSessionScope -Event $Event
    $sessionShort = Get-CphShortSessionId -Session $sessionScope
    $hostname = ''
    if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Trim() -ne '') { $hostname = $env:COMPUTERNAME }
    $eventName = $Event['HookEvent']
    if ([string]::IsNullOrEmpty($eventName)) { $eventName = $EventType }
    $statusLabel = 'Error ⚠️'
    $statusColor = 'red'
    $summarySource = ''
    if ($EventKind -eq 'user_input') {
        $statusLabel = 'Reply needed 🔔'
        $statusColor = 'orange'
        if ($Event['QuestionHeader'] -ne '') { $summarySource = $Event['QuestionHeader'] }
        elseif ($Event['QuestionText'] -ne '') { $summarySource = $Event['QuestionText'] }
        else { $summarySource = ($agent + ' is waiting for your input') }
    } else {
        if ($EventType -eq 'notification') {
            if ($Event['NotificationType'] -eq 'idle_prompt') {
                $statusLabel = 'Awaiting response ⏳'
                $statusColor = 'blue'
                if ($Event['Message'] -ne '') { $summarySource = $Event['Message'] }
                else { $summarySource = 'Waiting for your response' }
            } else {
                $statusLabel = 'Approval needed 🔔'
                $statusColor = 'orange'
                if ($Event['Message'] -ne '') { $summarySource = $Event['Message'] }
                else { $summarySource = 'Your action is needed' }
            }
        } elseif ($EventType -eq 'stop') {
            $statusLabel = 'Task complete ✅'
            $statusColor = 'green'
            $fl = Get-CphFirstLine -Text $Event['LastAssistantMessage']
            if ($fl -ne '') { $summarySource = $fl }
            else { $summarySource = 'Task completed' }
        } else {
            $statusLabel = 'Error ⚠️'
            $statusColor = 'red'
            if ($Event['Message'] -ne '') { $summarySource = $Event['Message'] }
            elseif ($Event['HookEvent'] -ne '') { $summarySource = $Event['HookEvent'] }
            else { $summarySource = 'New event' }
        }
    }
    $short = Truncate-CphText -Text (Compress-CphWhitespace -Text (Get-CphFirstLine -Text $summarySource)) -MaxLen 120
    if ([string]::IsNullOrEmpty($short)) {
        if (-not [string]::IsNullOrEmpty($eventName)) { $short = $eventName }
        else { $short = 'New event' }
    }
    $title = ($agent + ' · ' + $statusLabel)
    $toolName = $Event['ToolName']
    if ($EventKind -eq 'user_input') {
        $sess = $sessionShort
        if ([string]::IsNullOrEmpty($sess)) { $sess = 'unknown' }
        $body = ('[' + $project + '] ' + $short + ' · Questions: ' + [string]$Event['QuestionCount'] + ' · Session ' + $sess)
    } else {
        $body = ('[' + $project + '] ' + $short)
        if (-not [string]::IsNullOrEmpty($toolName)) { $body = ($body + ' · ' + $toolName) }
    }
    $evt = @{
        schema_version = 1
        title = $title
        body = $body
        agent = $agent
        project = $project
        status_label = $statusLabel
        status_color = $statusColor
        summary_short = $short
        event_name = $eventName
        event_kind = $EventKind
        tool_name = $toolName
        model = $Event['Model']
        cwd = $Event['Cwd']
        hostname = $hostname
        session_id = $Event['SessionId']
        session_short = $sessionShort
        question_count = [int]$Event['QuestionCount']
        option_labels = $Event['OptionLabels']
    }
    return @{
        Title = $title
        Body = $body
        Agent = $agent
        Project = $project
        StatusLabel = $statusLabel
        StatusColor = $statusColor
        SummaryShort = $short
        EventName = $eventName
        EventKind = $EventKind
        ToolName = $toolName
        Model = $Event['Model']
        Cwd = $Event['Cwd']
        Hostname = $hostname
        SessionId = $Event['SessionId']
        SessionShort = $sessionShort
        QuestionCount = [int]$Event['QuestionCount']
        OptionLabels = $Event['OptionLabels']
        EventObject = $evt
    }
}

#region Filters, rate limiting and pending state

function Get-CphRateLimit {
    param([string]$ConfigPath)
    $def = 10
    try {
        $cfg = Read-CphJsonFile -Path $ConfigPath
        if ($null -eq $cfg) { return $def }
        $rl = Get-CphRawField -Object $cfg -Name 'rate_limit'
        if ($rl -is [int] -or $rl -is [long] -or $rl -is [double]) {
            $n = [int]$rl
            if ($n -ge 0) { return $n }
            return $def
        }
        if ($rl -is [string] -and $rl -match '^[0-9]+$') { return [int]$rl }
    } catch { }
    return $def
}

function Test-CphNotifyFilter {
    param([hashtable]$Event, [string]$EventType = 'unknown', [string]$EventKind = '', [string]$StateDir = '', [int]$RateLimit = 10)
    if ([string]::IsNullOrEmpty($EventKind)) { $EventKind = $EventType }
    if ($Event['AgentId'] -ne '') { return @{ Skip = $true; Reason = 'subagent' } }
    if ($EventType -eq 'stop' -and $Event['StopHookActive'] -eq $true) {
        return @{ Skip = $true; Reason = 'stop_hook_active' }
    }
    $scope = Get-CphSessionScope -Event $Event
    $sessionKey = ConvertTo-CphSafeKey -Value $scope
    $kindKey = ConvertTo-CphSafeKey -Value $EventKind
    $toolUseKey = ConvertTo-CphSafeKey -Value $Event['ToolUseId']
    if ([string]::IsNullOrEmpty($Event['ToolUseId'])) { $toolUseKey = 'no-call' }
    if ($EventType -eq 'stop' -and $StateDir -ne '') {
        $exitMarker = Join-Path $StateDir ('exiting_' + $sessionKey)
        if (Test-Path -LiteralPath $exitMarker) {
            try { Remove-Item -LiteralPath $exitMarker -Force -ErrorAction SilentlyContinue } catch { }
            return @{ Skip = $true; Reason = 'exiting' }
        }
    }
    if ([string]::IsNullOrEmpty($StateDir)) { return @{ Skip = $false; Reason = '' } }
    $rateFile = Join-Path $StateDir ('last_' + $sessionKey + '_' + $kindKey)
    if (Test-Path -LiteralPath $rateFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($rateFile, [System.Text.Encoding]::UTF8)
            $line = ($raw -split "`r?`n" | Select-Object -First 1)
            if ($null -eq $line) { $line = '' }
            $parts = $line -split "`t"
            $last = 0
            $lastKey = ''
            if ($parts.Length -ge 1) { [int]::TryParse($parts[0].Trim(), [ref]$last) | Out-Null }
            if ($parts.Length -ge 2) { $lastKey = $parts[1] }
            $now = [int][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($EventKind -eq 'user_input' -and $Event['ToolUseId'] -ne '') {
                if ($lastKey -eq $toolUseKey) { return @{ Skip = $true; Reason = 'dedupe' } }
            } elseif (($now - $last) -lt $RateLimit) {
                return @{ Skip = $true; Reason = 'rate_limit' }
            }
        } catch { }
    }
    try {
        $now2 = [int][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $dir = Split-Path -Parent $rateFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($rateFile, ($now2.ToString() + "`t" + $toolUseKey + "`n"), [System.Text.Encoding]::UTF8)
    } catch { }
    return @{ Skip = $false; Reason = '' }
}

function Clear-CphPending {
    param([string]$StateDir, [string]$SessionKey, [string]$KindKey = '')
    if ([string]::IsNullOrEmpty($StateDir)) { return }
    if ([string]::IsNullOrEmpty($SessionKey)) { return }
    try {
        if ([string]::IsNullOrEmpty($KindKey)) { $pat = ('pending_' + $SessionKey + '_*') }
        else { $pat = ('pending_' + $SessionKey + '_' + $KindKey + '_*') }
        Get-ChildItem -LiteralPath $StateDir -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
}

function Clear-CphPendingFromEvent {
    param([hashtable]$Event, [string]$StateDir, [string]$KindFilter = '')
    $scope = Get-CphSessionScope -Event $Event
    $skey = ConvertTo-CphSafeKey -Value $scope
    if ($Event['HookEvent'] -eq 'UserPromptSubmit') {
        $msg = $Event['Message']
        # POSIX parity (clear_pending.sh): the whole message must be /exit,
        # so a prompt that merely contains a /exit line does not set the marker.
        if ($msg -match '^\s*/exit\s*$') {
            try {
                $m = Join-Path $StateDir ('exiting_' + $skey)
                $d = Split-Path -Parent $m
                if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                [System.IO.File]::WriteAllText($m, '', [System.Text.Encoding]::UTF8)
            } catch { }
        } else {
            try {
                $m2 = Join-Path $StateDir ('exiting_' + $skey)
                if (Test-Path -LiteralPath $m2) { Remove-Item -LiteralPath $m2 -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
    }
    $kk = ''
    if (-not [string]::IsNullOrEmpty($KindFilter)) { $kk = ConvertTo-CphSafeKey -Value $KindFilter }
    Clear-CphPending -StateDir $StateDir -SessionKey $skey -KindKey $kk
}

function New-CphPendingFile {
    param([string]$StateDir, [string]$SessionKey, [string]$KindKey, [string]$ToolUseKey, [string]$EventKind)
    try {
        Clear-CphPending -StateDir $StateDir -SessionKey $SessionKey
        $now = [int][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $name = ('pending_' + $SessionKey + '_' + $KindKey + '_' + $ToolUseKey + '_' + $now + '_' + $PID)
        $full = Join-Path $StateDir $name
        [System.IO.File]::WriteAllText($full, $EventKind, [System.Text.Encoding]::UTF8)
        return $full
    } catch { return $null }
}

#endregion

#region Queue

$script:CphWindowsChannels = @('bark','telegram','pushover','ntfy','gotify','wechat','feishu','dingtalk','slack','discord')

function Build-CphSendQueue {
    param([string]$ConfigPath, [string]$EventType = 'notification')
    $out = @()
    try {
        $cfg = Read-CphJsonFile -Path $ConfigPath
        if ($null -eq $cfg) { return @() }
        $channels = Get-CphRawField -Object $cfg -Name 'channels'
        if ($null -eq $channels) { return @() }
        $names = @()
        try {
            if ($channels -is [System.Collections.IDictionary]) { $names = @($channels.Keys) }
            else { $names = @($channels.PSObject.Properties | ForEach-Object { $_.Name }) }
        } catch { return @() }
        foreach ($name in $names) {
            if ($name -eq 'macos' -or $name -eq 'cmux') { continue }
            if ($script:CphWindowsChannels -notcontains $name) { continue }
            $ch = $null
            try {
                if ($channels -is [System.Collections.IDictionary]) { $ch = $channels[$name] }
                else { $ch = $channels.PSObject.Properties[$name].Value }
            } catch { continue }
            if ($null -eq $ch) { continue }
            $enabled = Get-CphRawField -Object $ch -Name 'enabled'
            if ($enabled -ne $true) { continue }
            $delay = 15
            try {
                $d = Get-CphRawField -Object $ch -Name 'delay'
                if ($d -is [int] -or $d -is [long] -or $d -is [double]) { $delay = [int]$d }
                elseif ($d -is [string] -and $d -match '^[0-9]+$') { $delay = [int]$d }
            } catch { }
            $ev = Get-CphRawField -Object $ch -Name 'events'
            if ($null -ne $ev) {
                $evList = @(ConvertTo-CphArray -Value $ev)
                if ($evList.Count -gt 0) {
                    $found = $false
                    foreach ($e in $evList) { if ([string]$e -eq $EventType) { $found = $true; break } }
                    if (-not $found) { continue }
                }
            }
            $out += @{ Channel = [string]$name; Delay = [int]$delay }
        }
    } catch { return @() }
    $sorted = $out | Sort-Object -Property Delay
    if ($null -eq $sorted) { return @() }
    return @($sorted)
}

#endregion

#region Long format (parity with notify_format.sh)

function Test-CphHasEventJson {
    param($EventObject)
    if ($null -eq $EventObject) { return $false }
    try {
        $sv = Get-CphRawField -Object $EventObject -Name 'schema_version'
        if ($sv -eq 1) { return $true }
    } catch { }
    return $false
}

function Get-CphLongNote {
    param([hashtable]$Content)
    $parts = @()
    if ($Content['Model'] -ne '') { $parts += $Content['Model'] }
    if ($Content['Cwd'] -ne '') { $parts += $Content['Cwd'] }
    if ($Content['Hostname'] -ne '') { $parts += $Content['Hostname'] }
    return ($parts -join ' · ')
}

function Get-CphLongMarkdown {
    param([hashtable]$Content)
    $lines = @()
    $lines += $Content['SummaryShort']
    $lines += ''
    $lines += ('**Project**: ' + $Content['Project'])
    $evn = $Content['EventName']
    if ([string]::IsNullOrEmpty($evn)) { $evn = 'unknown' }
    $lines += ('**Event**: ' + $evn)
    if ($Content['ToolName'] -ne '') { $lines += ('**Tool**: ' + $Content['ToolName']) }
    if ($Content['EventKind'] -eq 'user_input' -and [int]$Content['QuestionCount'] -gt 0) {
        $lines += ('**Questions**: ' + [string][int]$Content['QuestionCount'])
    }
    $opts = $Content['OptionLabels']
    if ($Content['EventKind'] -eq 'user_input' -and $null -ne $opts -and $opts.Count -gt 0) {
        $lines += ('**Options**: ' + ($opts -join ' / '))
    }
    $sessVal = ''
    if ($Content['EventKind'] -eq 'user_input') {
        if ($Content['SessionId'] -ne '') { $sessVal = $Content['SessionId'] }
        else { $sessVal = $Content['SessionShort'] }
    } else { $sessVal = $Content['SessionShort'] }
    if ($sessVal -ne '') { $lines += ('**Session**: ' + $sessVal) }
    $note = Get-CphLongNote -Content $Content
    if ($note -ne '') { $lines += ''; $lines += $note }
    return ($lines -join "`n")
}

function Get-CphColorDecimal {
    param([string]$Color)
    switch ($Color) {
        'green' { return 5763719 }
        'orange' { return 16753920 }
        'red' { return 15548997 }
        'blue' { return 3447003 }
        default { return 9807270 }
    }
}

#endregion

#region Channel request construction

function Get-CphChannelConfig {
    param([string]$ConfigPath, [string]$Channel)
    try {
        $cfg = Read-CphJsonFile -Path $ConfigPath
        if ($null -eq $cfg) { return $null }
        $channels = Get-CphRawField -Object $cfg -Name 'channels'
        if ($null -eq $channels) { return $null }
        if ($channels -is [System.Collections.IDictionary]) {
            if ($channels.Contains($Channel)) { return $channels[$Channel] }
            return $null
        }
        $p = $channels.PSObject.Properties[$Channel]
        if ($null -ne $p) { return $p.Value }
    } catch { }
    return $null
}

function New-CphChannelRequest {
    param([string]$Channel, [string]$Title, [string]$Body, $ChannelConfig, [hashtable]$Content)
    try {
        switch ($Channel) {
            'telegram' {
                $bot = Get-CphStringField -Object $ChannelConfig -Names @('bot_token')
                $chat = Get-CphStringField -Object $ChannelConfig -Names @('chat_id')
                if ($bot -eq '' -or $chat -eq '') { return $null }
                $payload = @{ chat_id = $chat; text = ($Title + "`n" + $Body) }
                return @{ Url = ('https://api.telegram.org/bot' + $bot + '/sendMessage'); Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'bark' {
                $key = Get-CphStringField -Object $ChannelConfig -Names @('key')
                if ($key -eq '') { return $null }
                $server = Get-CphStringField -Object $ChannelConfig -Names @('server')
                if ($server -eq '') { $server = 'https://api.day.app' }
                $server = $server.TrimEnd('/')
                $payload = @{ device_key = $key; title = $Title; body = $Body; level = 'timeSensitive'; group = 'claude-code' }
                $sound = Get-CphStringField -Object $ChannelConfig -Names @('sound')
                if ($sound -ne '') { $payload['sound'] = $sound }
                return @{ Url = ($server + '/push'); Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'pushover' {
                $app = Get-CphStringField -Object $ChannelConfig -Names @('app_token')
                $user = Get-CphStringField -Object $ChannelConfig -Names @('user_key')
                if ($app -eq '' -or $user -eq '') { return $null }
                return @{ Url = 'https://api.pushover.net/1/messages.json'; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }; Form = @{ token = $app; user = $user; title = $Title; message = $Body } }
            }
            'ntfy' {
                $topic = Get-CphStringField -Object $ChannelConfig -Names @('topic')
                if ($topic -eq '') { return $null }
                $server = Get-CphStringField -Object $ChannelConfig -Names @('server')
                if ($server -eq '') { $server = 'https://ntfy.sh' }
                $server = $server.TrimEnd('/')
                return @{ Url = ($server + '/' + $topic); Method = 'POST'; Headers = @{ Title = $Title; Priority = '4' }; TextBody = $Body }
            }
            'gotify' {
                $server = Get-CphStringField -Object $ChannelConfig -Names @('server')
                $token = Get-CphStringField -Object $ChannelConfig -Names @('app_token')
                if ($server -eq '' -or $token -eq '') { return $null }
                $server = $server.TrimEnd('/')
                $payload = @{ title = $Title; message = $Body; priority = 5 }
                return @{ Url = ($server + '/message?token=' + $token); Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'wechat' {
                $hook = Get-CphStringField -Object $ChannelConfig -Names @('webhook')
                if ($hook -eq '') { return $null }
                $format = Get-CphStringField -Object $ChannelConfig -Names @('format')
                if ($format -eq '') { $format = 'markdown' }
                $hasEvt = $false
                if ($null -ne $Content) { $hasEvt = Test-CphHasEventJson -EventObject $Content['EventObject'] }
                if ($format -eq 'text' -or -not $hasEvt) {
                    $payload = @{ msgtype = 'text'; text = @{ content = ($Title + "`n" + $Body) } }
                    return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
                }
                $md = Get-CphLongMarkdown -Content $Content
                $payload = @{ msgtype = 'markdown'; markdown = @{ content = ('**' + $Title + '**' + "`n`n" + $md) } }
                return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'feishu' {
                $hook = Get-CphStringField -Object $ChannelConfig -Names @('webhook')
                if ($hook -eq '') { return $null }
                $format = Get-CphStringField -Object $ChannelConfig -Names @('format')
                if ($format -eq '') { $format = 'card' }
                $hasEvt = $false
                if ($null -ne $Content) { $hasEvt = Test-CphHasEventJson -EventObject $Content['EventObject'] }
                if ($format -eq 'text' -or -not $hasEvt) {
                    $payload = @{ msg_type = 'text'; content = @{ text = ($Title + "`n" + $Body) } }
                    return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
                }
                $sessVal = ''
                if ($Content['EventKind'] -eq 'user_input') {
                    if ($Content['SessionId'] -ne '') { $sessVal = $Content['SessionId'] }
                    else { $sessVal = $Content['SessionShort'] }
                } else { $sessVal = $Content['SessionShort'] }
                $prj = $Content['Project']
                $evn2 = $Content['EventName']
                $fields = @(
                    @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Project**' + "`n" + $prj) } },
                    @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Event**' + "`n" + $evn2) } }
                )
                if ($Content['ToolName'] -ne '') { $fields += @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Tool**' + "`n" + $Content['ToolName']) } } }
                if ($Content['EventKind'] -eq 'user_input' -and [int]$Content['QuestionCount'] -gt 0) { $fields += @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Questions**' + "`n" + [string][int]$Content['QuestionCount']) } } }
                $opts = $Content['OptionLabels']
                if ($Content['EventKind'] -eq 'user_input' -and $null -ne $opts -and $opts.Count -gt 0) { $fields += @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Options**' + "`n" + ($opts -join ' / ')) } } }
                if ($sessVal -ne '') { $fields += @{ is_short = $true; text = @{ tag = 'lark_md'; content = ('**Session**' + "`n" + $sessVal) } } }
                $note = Get-CphLongNote -Content $Content
                $payload = @{
                    msg_type = 'interactive'
                    card = @{
                        config = @{ wide_screen_mode = $true }
                        header = @{ template = $Content['StatusColor']; title = @{ tag = 'plain_text'; content = $Title } }
                        elements = @(
                            @{ tag = 'div'; text = @{ tag = 'lark_md'; content = $Content['SummaryShort'] } },
                            @{ tag = 'div'; fields = $fields },
                            @{ tag = 'hr' },
                            @{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = $note }) }
                        )
                    }
                }
                return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'dingtalk' {
                $hook = Get-CphStringField -Object $ChannelConfig -Names @('webhook')
                if ($hook -eq '') { return $null }
                $format = Get-CphStringField -Object $ChannelConfig -Names @('format')
                if ($format -eq '') { $format = 'markdown' }
                $hasEvt = $false
                if ($null -ne $Content) { $hasEvt = Test-CphHasEventJson -EventObject $Content['EventObject'] }
                if ($format -eq 'text' -or -not $hasEvt) {
                    $payload = @{ msgtype = 'text'; text = @{ content = ($Title + "`n" + $Body) } }
                    return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
                }
                $md = Get-CphLongMarkdown -Content $Content
                $text = ('### ' + $Title + "`n`n" + $md)
                $payload = @{ msgtype = 'markdown'; markdown = @{ title = $Title; text = $text } }
                return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'slack' {
                $hook = Get-CphStringField -Object $ChannelConfig -Names @('webhook')
                if ($hook -eq '') { return $null }
                $format = Get-CphStringField -Object $ChannelConfig -Names @('format')
                if ($format -eq '') { $format = 'markdown' }
                $hasEvt = $false
                if ($null -ne $Content) { $hasEvt = Test-CphHasEventJson -EventObject $Content['EventObject'] }
                if ($format -eq 'text' -or -not $hasEvt) {
                    $payload = @{ text = ('*' + $Title + '*' + "`n" + $Body) }
                    return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
                }
                $md = Get-CphLongMarkdown -Content $Content
                $mdSlack = $md -replace '\*\*', '*'
                $payload = @{
                    text = ($Title + "`n" + $mdSlack)
                    blocks = @(
                        @{ type = 'section'; text = @{ type = 'mrkdwn'; text = ('*' + $Title + '*') } },
                        @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $mdSlack } }
                    )
                }
                return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
            'discord' {
                $hook = Get-CphStringField -Object $ChannelConfig -Names @('webhook')
                if ($hook -eq '') { return $null }
                $format = Get-CphStringField -Object $ChannelConfig -Names @('format')
                if ($format -eq '') { $format = 'embed' }
                $hasEvt = $false
                if ($null -ne $Content) { $hasEvt = Test-CphHasEventJson -EventObject $Content['EventObject'] }
                if ($format -eq 'text' -or -not $hasEvt) {
                    $payload = @{ content = ('**' + $Title + '**' + "`n" + $Body) }
                    return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
                }
                $sessVal = ''
                if ($Content['EventKind'] -eq 'user_input') {
                    if ($Content['SessionId'] -ne '') { $sessVal = $Content['SessionId'] }
                    else { $sessVal = $Content['SessionShort'] }
                } else { $sessVal = $Content['SessionShort'] }
                $fields = @(
                    @{ name = 'Project'; value = $Content['Project']; inline = $true },
                    @{ name = 'Event'; value = $Content['EventName']; inline = $true }
                )
                if ($Content['ToolName'] -ne '') { $fields += @{ name = 'Tool'; value = $Content['ToolName']; inline = $true } }
                if ($Content['EventKind'] -eq 'user_input' -and [int]$Content['QuestionCount'] -gt 0) { $fields += @{ name = 'Questions'; value = ([string][int]$Content['QuestionCount']); inline = $true } }
                $opts = $Content['OptionLabels']
                if ($Content['EventKind'] -eq 'user_input' -and $null -ne $opts -and $opts.Count -gt 0) { $fields += @{ name = 'Options'; value = ($opts -join ' / '); inline = $false } }
                if ($sessVal -ne '') { $fields += @{ name = 'Session'; value = $sessVal; inline = $true } }
                $footer = Get-CphLongNote -Content $Content
                $payload = @{
                    embeds = @(@{
                        title = $Title
                        description = $Content['SummaryShort']
                        color = (Get-CphColorDecimal -Color $Content['StatusColor'])
                        fields = $fields
                        footer = @{ text = $footer }
                    })
                }
                return @{ Url = $hook; Method = 'POST'; Headers = @{ 'Content-Type' = 'application/json' }; BodyObject = $payload }
            }
        }
    } catch { return $null }
    return $null
}
#endregion

#region Delivery - failures never block Codex
function Invoke-CphChannelSend {
    param([string]$Channel, [string]$Title, [string]$Body, $ChannelConfig, [hashtable]$Content)
    try {
        $req = New-CphChannelRequest -Channel $Channel -Title $Title -Body $Body -ChannelConfig $ChannelConfig -Content $Content
        if ($null -eq $req) { return $false }
        $capture = $env:CC_NOTIFY_CAPTURE_DIR
        if ($capture -and (Test-Path -LiteralPath $capture)) {
            try {
                # Capture mode exists for deterministic tests, so it records the
                # request SHAPE only. Destination URLs are deliberately omitted
                # (Telegram and Gotify embed their token in the URL, and every
                # webhook URL is itself a credential), and payload/form values are
                # replaced by their sorted key names. No credential is ever written.
                $kind = 'text'
                $keys = @()
                if ($req.ContainsKey('BodyObject')) {
                    $kind = 'json'
                    $keys = @($req['BodyObject'].Keys | Sort-Object)
                } elseif ($req.ContainsKey('Form')) {
                    $kind = 'form'
                    $keys = @($req['Form'].Keys | Sort-Object)
                }
                $scheme = ''
                try {
                    $m = [System.Text.RegularExpressions.Regex]::Match([string]$req['Url'], '^([A-Za-z][A-Za-z0-9+.-]*)://')
                    if ($m.Success) { $scheme = $m.Groups[1].Value }
                } catch { }
                $cap = @{
                    channel = [string]$Channel
                    method = [string]$req['Method']
                    captured = $true
                    body_kind = $kind
                    url_scheme = $scheme
                    field_keys = $keys
                }
                $fn = ($Channel + '_' + [System.Guid]::NewGuid().ToString('N') + '.json')
                $json = ($cap | ConvertTo-Json -Depth 6)
                [System.IO.File]::WriteAllText((Join-Path $capture $fn), $json, (New-Object System.Text.UTF8Encoding($false)))
                return $true
            } catch { return $false }
        }
        if ($Channel -eq 'pushover') {
            $pairs = @()
            foreach ($k in $req['Form'].Keys) {
                $pairs += ([System.Uri]::EscapeDataString($k) + '=' + [System.Uri]::EscapeDataString([string]$req['Form'][$k]))
            }
            $enc = ($pairs -join '&')
            Invoke-RestMethod -Uri $req['Url'] -Method Post -Body $enc -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 10 | Out-Null
            return $true
        }
        if ($req.ContainsKey('TextBody')) {
            Invoke-RestMethod -Uri $req['Url'] -Method Post -Headers $req['Headers'] -Body ([string]$req['TextBody']) -TimeoutSec 10 | Out-Null
            return $true
        }
        $json = ($req['BodyObject'] | ConvertTo-Json -Depth 20 -Compress)
        Invoke-RestMethod -Uri $req['Url'] -Method Post -Headers $req['Headers'] -Body $json -ContentType 'application/json' -TimeoutSec 10 | Out-Null
        return $true
    } catch { return $false }
}
#endregion

#region Jobs - job files carry paths and event data, never credentials
function New-CphJobFile {
    param([string]$StateDir, [hashtable]$Job)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
        $name = ('job_' + [System.Guid]::NewGuid().ToString('N') + '.json')
        $full = Join-Path $StateDir $name
        $Job | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $full -Encoding utf8
        return $full
    } catch { return $null }
}
#endregion

Export-ModuleMember -Function @(
    'Get-CphHomeDirectory', 'Get-CphCodexHome', 'Get-CphReasonixHome', 'Get-CphDshHome',
    'Find-CphNotifyConfig', 'Get-CphStateDirectory', 'Ensure-CphStateDirectory',
    'Get-CphRawField', 'Get-CphStringField', 'Read-CphJsonObject', 'Read-CphJsonFile', 'ConvertTo-CphArray',
    'ConvertTo-CphSafeKey', 'ConvertFrom-CphHookJson', 'Get-CphAgentName',
    'Get-CphFirstLine', 'Compress-CphWhitespace', 'Truncate-CphText',
    'Get-CphShortSessionId', 'Get-CphProjectName', 'Get-CphSessionScope',
    'Get-CphNotificationContent', 'Get-CphRateLimit', 'Test-CphNotifyFilter',
    'Clear-CphPending', 'Clear-CphPendingFromEvent', 'New-CphPendingFile',
    'Build-CphSendQueue', 'Test-CphHasEventJson', 'Get-CphLongNote',
    'Get-CphLongMarkdown', 'Get-CphColorDecimal', 'Get-CphChannelConfig',
    'New-CphChannelRequest', 'Invoke-CphChannelSend', 'New-CphJobFile'
    )
