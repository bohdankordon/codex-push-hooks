# test_windows.ps1 - native Windows test suite (no Pester, no network).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test_windows.ps1
# Uses Windows PowerShell 5.1 as the baseline; also passes on PowerShell 7.
# Channel sends are captured via CC_NOTIFY_CAPTURE_DIR, never the network.
$ErrorActionPreference = 'Stop'
$TestRoot = Split-Path -Parent $PSCommandPath
$ModulePath = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'CodexPushHooks.psm1'
Import-Module $ModulePath -Force -DisableNameChecking
$script:Passed = 0
$script:Failed = 0
$script:Failures = @()
$SavedEnv = @{}
foreach ($k in @('CC_NOTIFY_CONFIG','CC_NOTIFY_STATE_DIR','CC_NOTIFY_RENDER_ONLY','CC_NOTIFY_CAPTURE_DIR','CC_NOTIFY_AGENT','PLUGIN_DATA','PLUGIN_ROOT','CLAUDE_PLUGIN_DATA','REASONIX_PLUGIN_ROOT','DSH_CC_NOTIFY','CODEX_HOME','REASONIX_HOME','DSH_HOME','HOME')) {
    $SavedEnv[$k] = [System.Environment]::GetEnvironmentVariable($k)
}
function Reset-CaseEnv {
    foreach ($k in @('CC_NOTIFY_CONFIG','CC_NOTIFY_STATE_DIR','CC_NOTIFY_RENDER_ONLY','CC_NOTIFY_CAPTURE_DIR','CC_NOTIFY_AGENT','PLUGIN_DATA','PLUGIN_ROOT','CLAUDE_PLUGIN_DATA','REASONIX_PLUGIN_ROOT','DSH_CC_NOTIFY','CODEX_HOME','REASONIX_HOME','DSH_HOME')) {
        try { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue } catch { }
    }
}
function Restore-SavedEnv {
    foreach ($k in $SavedEnv.Keys) {
        if ($null -eq $SavedEnv[$k]) { try { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue } catch { } }
        else { Set-Item -Path ("env:" + $k) -Value $SavedEnv[$k] }
    }
}
function New-CaseDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('cphw-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}
function Write-TestConfig {
    param([string]$Dir, [string]$Body)
    $p = Join-Path $Dir 'notify.json'
    [System.IO.File]::WriteAllText($p, $Body, [System.Text.Encoding]::UTF8)
    return $p
}
function Assert-True {
    param([bool]$Cond, [string]$Msg)
    if (-not $Cond) { throw ('assert failed: ' + $Msg) }
}
function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    Reset-CaseEnv
    try {
        & $Body
        $script:Passed++
        Write-Output ("PASS " + $Name)
    } catch {
        $script:Failed++
        $script:Failures += $Name
        Write-Output ("FAIL " + $Name + " :: " + $_.Exception.Message)
    }
}
function Get-HookStdout {
    param([string]$Json, [string]$Action, [string]$Kind = '', [hashtable]$ExtraEnv = @{})
    $hook = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'hook.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hook + '" ' + $Action
    if ($Kind -ne '') { $psi.Arguments = $psi.Arguments + ' ' + $Kind }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
    $psi.EnvironmentVariables['CC_NOTIFY_RENDER_ONLY'] = '1'
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Json)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(15000) | Out-Null
    return @{ Code = $p.ExitCode; Out = $out }
}
function Get-HookExit {
    param([string]$Json, [string]$Action, [string]$Kind = '', [hashtable]$ExtraEnv = @{})
    $hook = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'hook.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hook + '" ' + $Action
    if ($Kind -ne '') { $psi.Arguments = $psi.Arguments + ' ' + $Kind }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Json)
    $p.StandardInput.Close()
    $p.WaitForExit(15000) | Out-Null
    return $p.ExitCode
}

# Runs the real pre-tool-use action against an isolated state dir whose config
# enables no channels (so no worker spawns) and returns the hook exit code.
# Pending markers created by the call remain visible in <Dir>/state.
function Invoke-AsyncPreToolUse {
    param([string]$Json, [string]$Dir)
    $sd = Join-Path $Dir 'state'
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cfg = Write-TestConfig -Dir $Dir -Body '{"channels":{}}'
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd; 'CC_NOTIFY_CONFIG' = $cfg }
    return Get-HookExit -Json $Json -Action 'pre-tool-use' -ExtraEnv $extra
}

# Shared assertions for an async payload the Codex handler will reject: quiet in
# render mode, quiet through the real action path, no new pending marker, and an
# existing pending marker left untouched.
function Assert-InvalidAsyncPayload {
    param([string]$Name, [string]$Json)
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $pend = Join-Path $sd ('pending_' + $Name + '_user_input_x_1_1')
    [System.IO.File]::WriteAllText($pend, 'user_input', [System.Text.Encoding]::UTF8)
    $e = ConvertFrom-CphHookJson -RawJson $Json
    Assert-True ($e['AsyncQuestionPayloadValid'] -eq $false) ($Name + ' is flagged as an invalid async payload')
    $render = Get-HookStdout -Json $Json -Action 'pre-tool-use' -ExtraEnv @{ 'CC_NOTIFY_STATE_DIR' = $sd }
    Assert-True ($render.Code -eq 0) ($Name + ' exits 0 in render mode')
    Assert-True ([string]::IsNullOrWhiteSpace($render.Out)) ($Name + ' renders no notification')
    $code = Invoke-AsyncPreToolUse -Json $Json -Dir $d
    Assert-True ($code -eq 0) ($Name + ' exits 0 on the real action path')
    Assert-True (Test-Path -LiteralPath $pend) ($Name + ' keeps existing pending state')
    Assert-True (@(Get-ChildItem -LiteralPath $sd -Filter 'pending_*').Count -eq 1) ($Name + ' creates no new pending marker')
}

# Decodes the quote-free -EncodedCommand bootstrap carried by a
function New-AsyncCaseEnv {
    # Configured notifier with a long delay and a capture dir: a real queue
    # exists (so async waiting state is created) and no real send can occur.
    param([string]$Dir)
    $sd = Join-Path $Dir 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cap = Join-Path $Dir 'cap'; New-Item -ItemType Directory -Force -Path $cap | Out-Null
    $cfg = Write-TestConfig -Dir $Dir -Body '{"channels":{"telegram":{"enabled":true,"delay":60,"bot_token":"F","chat_id":"0"}},"rate_limit":0}'
    return @{ StateDir = $sd; CaptureDir = $cap; Config = $cfg; Extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd; 'CC_NOTIFY_CONFIG' = $cfg; 'CC_NOTIFY_CAPTURE_DIR' = $cap } }
}

function Add-AsyncAwaitingFixture {
    param([string]$StateDir, [string]$SessionKey, [string]$ToolUseKey)
    [void](Set-CphAsyncAwaiting -StateDir $StateDir -SessionKey $SessionKey -ToolUseKey $ToolUseKey)
    [System.IO.File]::WriteAllText((Join-Path $StateDir ('pending_' + $SessionKey + '_user_input_' + $ToolUseKey + '_1_1')), 'user_input', [System.Text.Encoding]::UTF8)
}

# Decodes the quote-free -EncodedCommand bootstrap carried by a
# commandWindows entry, so tests can assert what the opaque payload does.
function Get-DecodedHookCommand {
    param([string]$Cmd)
    $m = [regex]::Match($Cmd, '-EncodedCommand\s+([A-Za-z0-9+/=]+)\s*$')
    Assert-True ($m.Success) 'command carries a trailing -EncodedCommand payload'
    return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($m.Groups[1].Value))
}

# Emulates the current Codex Windows command-hook runner shape,
# COMSPEC /C "<commandWindows>", with the argument string, environment and
# redirected stdin owned by this test process (no extra PowerShell layer).
function Invoke-CmdWrappedCommand {
    param([string]$CmdLine, [string]$StdIn = '', [hashtable]$ExtraEnv = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:COMSPEC
    $psi.Arguments = '/C "' + $CmdLine + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($StdIn)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(30000) | Out-Null
    return @{ Code = $p.ExitCode; Out = $out }
}

# Same command line handed to a PowerShell-family outer shell instead of cmd.exe.
function Invoke-PsWrappedCommand {
    param([string]$CmdLine, [string]$StdIn = '', [hashtable]$ExtraEnv = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + $CmdLine
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($StdIn)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(30000) | Out-Null
    return @{ Code = $p.ExitCode; Out = $out }
}

function Get-FirstBytes {
    param([string]$Path, [int]$Count = 3)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return $bytes[0..($Count - 1)]
}
Invoke-Case '01-json-stdin-parsing' {
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"PermissionRequest","session_id":"abc","turn_id":"t1","tool_use_id":"call1","transcript_path":"x","cwd":"C:/w/proj","permission_mode":"default","agent_id":"","notification_type":"","model":"gpt-5","tool_name":"Bash","last_assistant_message":"hi","stop_hook_active":false,"tool_input":{"questions":[{"header":"H","question":"Q?","options":[{"label":"Yes"},{"label":"No"}]}]}}'
    Assert-True ($e['HookEvent'] -eq 'PermissionRequest') 'hook event'
    Assert-True ($e['SessionId'] -eq 'abc') 'session'
    Assert-True ($e['TurnId'] -eq 't1') 'turn'
    Assert-True ($e['ToolUseId'] -eq 'call1') 'tool_use_id'
    Assert-True ($e['Cwd'] -eq 'C:/w/proj') 'cwd'
    Assert-True ($e['Model'] -eq 'gpt-5') 'model'
    Assert-True ($e['ToolName'] -eq 'Bash') 'tool name'
    Assert-True ($e['QuestionCount'] -eq 1) 'question count'
    Assert-True ($e['QuestionHeader'] -eq 'H') 'header'
    Assert-True ($e['OptionLabels'].Count -eq 2) 'options'
    Assert-True ($e['StopHookActive'] -eq $false) 'stop flag'
    $bad = ConvertFrom-CphHookJson -RawJson 'not json{{{'; Assert-True ($null -eq $bad) 'malformed null'
    $arr = ConvertFrom-CphHookJson -RawJson '[1,2]'; Assert-True ($null -eq $arr) 'array null'
}
Invoke-Case '02-permission-request-render' {
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"PermissionRequest","prompt":"Allow deploy?","cwd":"C:/w/shop","session_id":"sess-001"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'notification'
    Assert-True ($c['Agent'] -eq 'Codex') 'agent codex'
    Assert-True ($c['Title'] -match 'Approval needed') 'title approval'
    Assert-True ($c['Body'] -eq '[shop] Allow deploy?') 'body project summary'
    Assert-True ($c['EventObject']['schema_version'] -eq 1) 'schema'
    $r = Get-HookStdout -Json '{"hook_event_name":"PermissionRequest","prompt":"Allow deploy?","cwd":"C:/w/shop","session_id":"sess-001"}' -Action 'notification'
    Assert-True ($r['Code'] -eq 0) 'hook exit 0'
    Assert-True ($r['Out'] -match 'Allow deploy\?') 'hook stdout renders'
}
Invoke-Case '03-stop-render' {
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","last_assistant_message":"Finished all tasks\nsecond line","cwd":"C:/w/shop","session_id":"sess-002"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'stop' -EventKind 'stop'
    Assert-True ($c['Title'] -match 'Task complete') 'title complete'
    Assert-True ($c['Body'] -eq '[shop] Finished all tasks') 'body first line'
    Assert-True ($c['StatusColor'] -eq 'green') 'green'
}
Invoke-Case '04-request-user-input-render' {
    $raw = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"call-9","cwd":"C:/w/shop","session_id":"019eabcd12345678","tool_input":{"questions":[{"header":"Pick","question":"Which one?","options":[{"label":"A"},{"label":"B"}]},{"header":"H2","question":"Q2","options":[]}]}}'
    $e = ConvertFrom-CphHookJson -RawJson $raw
    Assert-True ($e['QuestionCount'] -eq 2) 'two questions'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'user_input'
    Assert-True ($c['Title'] -match 'Reply needed') 'reply title'
    Assert-True ($c['Body'] -match 'Questions: 2') 'question count in body'
    Assert-True ($c['Body'] -match 'Session 019eabcd') 'short session in body'
    Assert-True ($c['OptionLabels'].Count -eq 2) 'option labels'
    Assert-True ($c['EventObject']['question_count'] -eq 2) 'event question_count'
}
Invoke-Case '05-subagent-filter' {
    $d = New-CaseDir; $env:CC_NOTIFY_STATE_DIR = (Join-Path $d 'state'); New-Item -ItemType Directory -Force -Path $env:CC_NOTIFY_STATE_DIR | Out-Null
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","agent_id":"agent-1","session_id":"s1"}'
    $f = Test-CphNotifyFilter -Event $e -EventType 'stop' -EventKind 'stop' -StateDir $env:CC_NOTIFY_STATE_DIR -RateLimit 10
    Assert-True ($f['Skip'] -eq $true) 'subagent skipped'
}
Invoke-Case '06-stop-hook-active-filter' {
    $d = New-CaseDir; $env:CC_NOTIFY_STATE_DIR = (Join-Path $d 'state'); New-Item -ItemType Directory -Force -Path $env:CC_NOTIFY_STATE_DIR | Out-Null
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"s1"}'
    $f = Test-CphNotifyFilter -Event $e -EventType 'stop' -EventKind 'stop' -StateDir $env:CC_NOTIFY_STATE_DIR -RateLimit 10
    Assert-True ($f['Skip'] -eq $true) 'loop skipped'
}
Invoke-Case '07-exit-marker' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $up = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"UserPromptSubmit","message":"/exit","session_id":"sess-x"}'
    Clear-CphPendingFromEvent -Event $up -StateDir $sd -KindFilter ''
    Assert-True (Test-Path -LiteralPath (Join-Path $sd 'exiting_sess-x')) 'marker created'
    $st = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","session_id":"sess-x"}'
    $f = Test-CphNotifyFilter -Event $st -EventType 'stop' -EventKind 'stop' -StateDir $sd -RateLimit 10
    Assert-True ($f['Skip'] -eq $true) 'stop after exit skipped'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sd 'exiting_sess-x'))) 'marker consumed'
    $up2 = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"UserPromptSubmit","message":"hello","session_id":"sess-x"}'
    Clear-CphPendingFromEvent -Event $up2 -StateDir $sd -KindFilter ''
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sd 'exiting_sess-x'))) 'normal message clears marker'
    $up3 = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"UserPromptSubmit","message":"explain /exit\nplease","session_id":"sess-x"}'
    Clear-CphPendingFromEvent -Event $up3 -StateDir $sd -KindFilter ''
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sd 'exiting_sess-x'))) 'message merely containing /exit does not set the marker'
}
Invoke-Case '08-session-pending' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sA_notification_no-call_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sB_notification_no-call_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    Clear-CphPending -StateDir $sd -SessionKey 'sA'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sd 'pending_sA_notification_no-call_1_1'))) 'session A cleared'
    Assert-True (Test-Path -LiteralPath (Join-Path $sd 'pending_sB_notification_no-call_1_1')) 'session B kept'
}
Invoke-Case '09-user-input-dedupe' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $mk = { param($t) ConvertFrom-CphHookJson -RawJson ('{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"' + $t + '","session_id":"s9","tool_input":{"questions":[{"header":"H","question":"Q","options":[]}]}}') }
    $f1 = Test-CphNotifyFilter -Event (& $mk 'call-A') -EventType 'notification' -EventKind 'user_input' -StateDir $sd -RateLimit 10
    Assert-True ($f1['Skip'] -eq $false) 'first passes'
    $f2 = Test-CphNotifyFilter -Event (& $mk 'call-A') -EventType 'notification' -EventKind 'user_input' -StateDir $sd -RateLimit 10
    Assert-True ($f2['Skip'] -eq $true) 'same call deduped'
    $f3 = Test-CphNotifyFilter -Event (& $mk 'call-B') -EventType 'notification' -EventKind 'user_input' -StateDir $sd -RateLimit 10
    Assert-True ($f3['Skip'] -eq $false) 'new call passes'
}
Invoke-Case '10-rate-limit' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $mk = { ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","session_id":"s10"}' }
    $f1 = Test-CphNotifyFilter -Event (& $mk) -EventType 'stop' -EventKind 'stop' -StateDir $sd -RateLimit 60
    Assert-True ($f1['Skip'] -eq $false) 'first passes'
    $f2 = Test-CphNotifyFilter -Event (& $mk) -EventType 'stop' -EventKind 'stop' -StateDir $sd -RateLimit 60
    Assert-True ($f2['Skip'] -eq $true) 'second rate limited'
    $f3 = Test-CphNotifyFilter -Event (& $mk) -EventType 'notification' -EventKind 'notification' -StateDir $sd -RateLimit 60
    Assert-True ($f3['Skip'] -eq $false) 'other kind passes'
}
Invoke-Case '11-canonical-discovery' {
    $d = New-CaseDir
    $env:CODEX_HOME = (Join-Path $d 'codex')
    $canon = Join-Path (Join-Path $env:CODEX_HOME 'codex-push-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $canon) | Out-Null
    Write-TestConfig -Dir (Split-Path -Parent $canon) -Body '{"channels":{},"rate_limit":10}' | Out-Null
    $found = Find-CphNotifyConfig
    Assert-True ($found -eq $canon) 'canonical codex found'
}
Invoke-Case '12-legacy-fallback' {
    $d = New-CaseDir
    $env:CODEX_HOME = (Join-Path $d 'codex')
    $env:REASONIX_HOME = (Join-Path $d 'reasonix')
    $env:DSH_HOME = (Join-Path $d 'dsh')
    $leg = Join-Path (Join-Path $env:CODEX_HOME 'cc-notify-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $leg) | Out-Null
    Write-TestConfig -Dir (Split-Path -Parent $leg) -Body '{"channels":{},"rate_limit":10}' | Out-Null
    $found = Find-CphNotifyConfig
    Assert-True ($found -eq $leg) 'legacy fallback found'
}
Invoke-Case '13-canonical-beats-legacy' {
    $d = New-CaseDir
    $env:CODEX_HOME = (Join-Path $d 'codex')
    $env:REASONIX_HOME = (Join-Path $d 'reasonix')
    $env:DSH_HOME = (Join-Path $d 'dsh')
    $leg = Join-Path (Join-Path $env:CODEX_HOME 'cc-notify-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $leg) | Out-Null
    Write-TestConfig -Dir (Split-Path -Parent $leg) -Body '{"channels":{}}' | Out-Null
    $dshCanon = Join-Path (Join-Path $env:DSH_HOME 'codex-push-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dshCanon) | Out-Null
    Write-TestConfig -Dir (Split-Path -Parent $dshCanon) -Body '{"channels":{}}' | Out-Null
    $found = Find-CphNotifyConfig
    Assert-True ($found -eq $dshCanon) 'any canonical beats any legacy'
}
Invoke-Case '14-explicit-config-wins' {
    $d = New-CaseDir
    $env:CODEX_HOME = (Join-Path $d 'codex')
    $canon = Join-Path (Join-Path $env:CODEX_HOME 'codex-push-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $canon) | Out-Null
    Write-TestConfig -Dir (Split-Path -Parent $canon) -Body '{"channels":{}}' | Out-Null
    $exp = Write-TestConfig -Dir $d -Body '{"channels":{}}'
    $env:CC_NOTIFY_CONFIG = $exp
    $found = Find-CphNotifyConfig
    Assert-True ($found -eq $exp) 'explicit override wins'
}
Invoke-Case '15-clear-current-session-only' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $ea = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"UserPromptSubmit","message":"hi","session_id":"sA"}'
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sA_notification_x_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sB_notification_x_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    Clear-CphPendingFromEvent -Event $ea -StateDir $sd -KindFilter ''
    Assert-True ((Get-ChildItem -LiteralPath $sd -Filter 'pending_sA_*' -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) 'A cleared'
    Assert-True ((Get-ChildItem -LiteralPath $sd -Filter 'pending_sB_*' -ErrorAction SilentlyContinue | Measure-Object).Count -eq 1) 'B kept'
}
Invoke-Case '16-user-input-only-clear' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sC_notification_x_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sd 'pending_sC_user_input_y_1_2'), 'user_input', [System.Text.Encoding]::UTF8)
    Clear-CphPending -StateDir $sd -SessionKey 'sC' -KindKey 'user_input'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sd 'pending_sC_user_input_y_1_2'))) 'user_input cleared'
    Assert-True (Test-Path -LiteralPath (Join-Path $sd 'pending_sC_notification_x_1_1')) 'notification kept'
}
Invoke-Case '17-event-filters' {
    $d = New-CaseDir
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"delay":5,"bot_token":"T","chat_id":"C","events":["stop"]}},"rate_limit":10}'
    $qN = @(Build-CphSendQueue -ConfigPath $cfg -EventType 'notification')
    Assert-True ($qN.Count -eq 0) 'notification filtered out'
    $qS = @(Build-CphSendQueue -ConfigPath $cfg -EventType 'stop')
    Assert-True ($qS.Count -eq 1) 'stop passes filter'
}
Invoke-Case '18-queue-sort' {
    $d = New-CaseDir
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"slack":{"enabled":true,"delay":300,"webhook":"https://w"},"bark":{"enabled":true,"delay":15,"key":"k"},"telegram":{"enabled":true,"delay":5,"bot_token":"T","chat_id":"C"}},"rate_limit":10}'
    $q = @(Build-CphSendQueue -ConfigPath $cfg -EventType 'notification')
    Assert-True ($q.Count -eq 3) 'three channels'
    Assert-True ($q[0]['Channel'] -eq 'telegram') 'telegram first'
    Assert-True ($q[1]['Channel'] -eq 'bark') 'bark second'
    Assert-True ($q[2]['Channel'] -eq 'slack') 'slack last'
}
Invoke-Case '19-telegram-request' {
    $d = New-CaseDir
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"delay":5,"bot_token":"TESTTOKEN","chat_id":"TESTCHAT"}}}'
    $ch = Get-CphChannelConfig -ConfigPath $cfg -Channel 'telegram'
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"PermissionRequest","prompt":"Go?","cwd":"C:/w/p","session_id":"s"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'notification'
    $req = New-CphChannelRequest -Channel 'telegram' -Title $c['Title'] -Body $c['Body'] -ChannelConfig $ch -Content $c
    Assert-True ($req['Url'] -eq 'https://api.telegram.org/botTESTTOKEN/sendMessage') 'bot url'
    Assert-True ($req['BodyObject']['chat_id'] -eq 'TESTCHAT') 'chat id'
    Assert-True ($req['BodyObject']['text'] -eq ($c['Title'] + "`n" + $c['Body'])) 'title newline body'
}
Invoke-Case '20-all-channel-requests' {
    $d = New-CaseDir
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"bark":{"enabled":true,"key":"K"},"telegram":{"enabled":true,"bot_token":"T","chat_id":"C"},"pushover":{"enabled":true,"app_token":"A","user_key":"U"},"ntfy":{"enabled":true,"topic":"t"},"gotify":{"enabled":true,"server":"https://g.example","app_token":"A"},"wechat":{"enabled":true,"webhook":"https://w.example"},"feishu":{"enabled":true,"webhook":"https://f.example"},"dingtalk":{"enabled":true,"webhook":"https://d.example"},"slack":{"enabled":true,"webhook":"https://s.example"},"discord":{"enabled":true,"webhook":"https://dc.example"}}}'
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","last_assistant_message":"Done","cwd":"C:/w/p","session_id":"s","model":"m"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'stop' -EventKind 'stop'
    foreach ($ch in @('bark','telegram','pushover','ntfy','gotify','wechat','feishu','dingtalk','slack','discord')) {
        $cc = Get-CphChannelConfig -ConfigPath $cfg -Channel $ch
        $req = New-CphChannelRequest -Channel $ch -Title $c['Title'] -Body $c['Body'] -ChannelConfig $cc -Content $c
        Assert-True ($null -ne $req) ($ch + ' builds a request')
        Assert-True ($req['Url'] -match '^https://') ($ch + ' url is https')
    }
    $cap = New-CaseDir
    $env:CC_NOTIFY_CAPTURE_DIR = $cap
    $ok = Invoke-CphChannelSend -Channel 'telegram' -Title 'T' -Body 'B' -ChannelConfig (Get-CphChannelConfig -ConfigPath $cfg -Channel 'telegram') -Content $c
    Assert-True ($ok -eq $true) 'capture send true'
    Assert-True ((Get-ChildItem -LiteralPath $cap -Filter '*.json' | Measure-Object).Count -eq 1) 'one capture file'
}
Invoke-Case '21-failure-safety' {
    $d = New-CaseDir
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"bot_token":"T","chat_id":"C"}}}'
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","session_id":"s"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'stop' -EventKind 'stop'
    $r = Invoke-CphChannelSend -Channel 'telegram' -Title 'T' -Body 'B' -ChannelConfig $null -Content $c
    Assert-True ($r -eq $false) 'null config returns false, no throw'
    $code = Get-HookExit -Json 'not json{{{' -Action 'notification'
    Assert-True ($code -eq 0) 'malformed hook exits 0'
    $code2 = Get-HookExit -Json '' -Action 'stop'
    Assert-True ($code2 -eq 0) 'empty hook exits 0'
}
Invoke-Case '22-worker-cancellation' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cap = Join-Path $d 'cap'; New-Item -ItemType Directory -Force -Path $cap | Out-Null
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"delay":1,"bot_token":"T","chat_id":"C"}}}'
    $pend = Join-Path $sd 'pending_s22_notification_x_1_1'
    [System.IO.File]::WriteAllText($pend, 'notification', [System.Text.Encoding]::UTF8)
    $job = @{ configPath = $cfg; eventType = 'notification'; eventKind = 'notification'; title = 'T'; body = 'B'; content = @{ EventObject = @{ schema_version = 1 } }; pendingFile = $pend; queue = @(@{ Channel = 'telegram'; Delay = 1 }); stateDir = $sd }
    $jp = New-CphJobFile -StateDir $sd -Job $job
    Remove-Item -LiteralPath $pend -Force
    $env:CC_NOTIFY_CAPTURE_DIR = $cap
    $worker = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'worker.ps1'
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -JobPath $jp
    Assert-True ((Get-ChildItem -LiteralPath $cap -Filter '*.json' -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) 'cancelled worker sends nothing'
    Assert-True (-not (Test-Path -LiteralPath $jp)) 'job cleaned up'
}
Invoke-Case '23-worker-cleanup' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cap = Join-Path $d 'cap'; New-Item -ItemType Directory -Force -Path $cap | Out-Null
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"delay":0,"bot_token":"T","chat_id":"C"}}}'
    $pend = Join-Path $sd 'pending_s23_notification_x_1_1'
    [System.IO.File]::WriteAllText($pend, 'notification', [System.Text.Encoding]::UTF8)
    $job = @{ configPath = $cfg; eventType = 'notification'; eventKind = 'notification'; title = 'T'; body = 'B'; content = @{ EventObject = @{ schema_version = 1 } }; pendingFile = $pend; queue = @(@{ Channel = 'telegram'; Delay = 0 }); stateDir = $sd }
    $jp = New-CphJobFile -StateDir $sd -Job $job
    Assert-True ($jp -match '\.json$') 'job file created'
    $env:CC_NOTIFY_CAPTURE_DIR = $cap
    $worker = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'worker.ps1'
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -JobPath $jp
    Assert-True ((Get-ChildItem -LiteralPath $cap -Filter '*.json' | Measure-Object).Count -eq 1) 'capture delivered'
    Assert-True (-not (Test-Path -LiteralPath $pend)) 'pending removed'
    Assert-True (-not (Test-Path -LiteralPath $jp)) 'job removed'
}
Invoke-Case '24-runner-cmd-wrapped-command' {
    # Regression for the current Codex Windows runner, which passes the handler to
    # COMSPEC /C "<commandWindows>". An embedded quoted segment is unsafe under
    # that wrapping, so every plugin command must be a quote-free
    # -EncodedCommand bootstrap that still reaches hook.ps1 when PLUGIN_ROOT
    # contains spaces.
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cphw plugin root ' + [System.Guid]::NewGuid().ToString('N'))
    $pluginCopy = Join-Path $root 'codex-push-hooks'
    New-Item -ItemType Directory -Force -Path $pluginCopy | Out-Null
    Copy-Item -Path (Join-Path $TestRoot '*') -Destination $pluginCopy -Recurse -Force
    $manifest = Get-Content (Join-Path $TestRoot 'hooks/codex-hooks.json') -Raw | ConvertFrom-Json
    $expect = @{ PermissionRequest = "'notification'"; Stop = "'stop'"; UserPromptSubmit = "'clear'"; PreToolUse = "'pre-tool-use'"; PostToolUse = "'clear' 'user_input'" }
    foreach ($ev in $expect.Keys) {
        $cmd = [string]$manifest.hooks.$ev[0].hooks[0].commandWindows
        Assert-True (-not $cmd.Contains('"')) ($ev + ' commandWindows contains no double quote')
        $decoded = Get-DecodedHookCommand -Cmd $cmd
        Assert-True ($decoded -match 'hook\.ps1') ($ev + ' bootstrap resolves hook.ps1')
        Assert-True ($decoded -match 'PLUGIN_ROOT') ($ev + ' bootstrap reads PLUGIN_ROOT')
        Assert-True ($decoded -match [regex]::Escape($expect[$ev])) ($ev + ' bootstrap carries the action args')
        Assert-True ($decoded -notmatch 'bash|jq|wsl') ($ev + ' bootstrap has no posix dependency')
    }
    $fixture = '{"hook_event_name":"PermissionRequest","prompt":"spaced plugin root","cwd":"C:/w/proj","session_id":"s24"}'
    $cmdLine = [string]$manifest.hooks.PermissionRequest[0].hooks[0].commandWindows
    $extra = @{ PLUGIN_ROOT = $pluginCopy; CC_NOTIFY_RENDER_ONLY = '1' }
    $r = Invoke-CmdWrappedCommand -CmdLine $cmdLine -StdIn $fixture -ExtraEnv $extra
    Assert-True ($r['Code'] -eq 0) 'cmd-wrapped runner exit 0'
    Assert-True ($r['Out'] -match 'spaced plugin root') 'cmd-wrapped runner reached hook.ps1 and read stdin'
    Assert-True ($r['Out'] -match '"schema_version"') 'cmd-wrapped runner produced a rendered event'
    $r2 = Invoke-PsWrappedCommand -CmdLine $cmdLine -StdIn $fixture -ExtraEnv $extra
    Assert-True ($r2['Code'] -eq 0) 'powershell-wrapped runner exit 0'
    Assert-True ($r2['Out'] -match 'spaced plugin root') 'powershell-wrapped runner reached hook.ps1 and read stdin'
}
Invoke-Case '25-unicode-roundtrip' {
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"PermissionRequest","prompt":"Deploy caf\u00e9 \u6771\u4eac done?","cwd":"C:/w/p","session_id":"s25"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'notification'
    Assert-True ($c['Body'] -match 'Deploy') 'unicode body keeps text'
    $d = New-CaseDir
    $jp = New-CphJobFile -StateDir $d -Job @{ configPath = 'x'; title = $c['Title']; body = $c['Body']; content = $c; pendingFile = 'y'; queue = @() }
    $back = Get-Content $jp -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($back.body -eq $c['Body']) 'job file preserves unicode body'
}
Invoke-Case '26-malformed-json-safe' {
    $code = Get-HookExit -Json '{"hook_event_name":' -Action 'notification'
    Assert-True ($code -eq 0) 'truncated json exits 0'
    $code2 = Get-HookExit -Json '[1,2,3]' -Action 'stop'
    Assert-True ($code2 -eq 0) 'array json exits 0'
    $code3 = Get-HookExit -Json '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s"}' -Action 'pre-tool-use'
    Assert-True ($code3 -eq 0) 'pre-tool-use non-question exits 0'
}
Invoke-Case '27-missing-config-safe' {
    $d = New-CaseDir
    $extra = @{ 'CODEX_HOME' = (Join-Path $d 'none'); 'CC_NOTIFY_STATE_DIR' = (Join-Path $d 'st') }
    $code = Get-HookExit -Json '{"hook_event_name":"Stop","session_id":"s27"}' -Action 'stop' -ExtraEnv $extra
    Assert-True ($code -eq 0) 'missing config exits 0'
}
Invoke-Case '28-command-windows-present' {
    $hooks = Get-Content (Join-Path $TestRoot 'hooks/codex-hooks.json') -Raw | ConvertFrom-Json
    $expect = @{ PermissionRequest = "'notification'"; Stop = "'stop'"; UserPromptSubmit = "'clear'"; PreToolUse = "'pre-tool-use'"; PostToolUse = "'clear' 'user_input'" }
    foreach ($ev in $expect.Keys) {
        $h = $hooks.hooks.$ev[0].hooks[0]
        Assert-True ($null -ne $h.commandWindows) ($ev + ' has commandWindows')
        Assert-True ($h.commandWindows -match '^powershell\.exe ') ($ev + ' uses powershell.exe')
        Assert-True ($h.commandWindows -match '-EncodedCommand [A-Za-z0-9+/=]+$') ($ev + ' carries an encoded bootstrap')
        Assert-True (-not $h.commandWindows.Contains('"')) ($ev + ' command line has no double quote')
        $decoded = Get-DecodedHookCommand -Cmd $h.commandWindows
        Assert-True ($decoded -match 'hook\.ps1') ($ev + ' targets hook.ps1')
        Assert-True ($decoded -match [regex]::Escape($expect[$ev])) ($ev + ' action args')
        Assert-True ($decoded -notmatch 'bash|jq|wsl') ($ev + ' has no posix deps')
    }
}
Invoke-Case '29-posix-commands-unchanged' {
    $raw = Get-Content (Join-Path $TestRoot 'hooks/codex-hooks.json') -Raw | ConvertFrom-Json
    # Permanent invariants: the POSIX command shape and timeouts are asserted
    # against literals so this regression survives every future commit.
    $expected = @{
        PermissionRequest = @{ Command = 'bash "${PLUGIN_ROOT}/scripts/notify.sh" notification'; Timeout = 5 }
        Stop              = @{ Command = 'bash "${PLUGIN_ROOT}/scripts/notify.sh" stop'; Timeout = 5 }
        UserPromptSubmit  = @{ Command = 'bash "${PLUGIN_ROOT}/scripts/clear_pending.sh"'; Timeout = 3 }
        PreToolUse        = @{ Command = 'bash "${PLUGIN_ROOT}/scripts/pre_tool_use.sh"'; Timeout = 3 }
        PostToolUse       = @{ Command = 'bash "${PLUGIN_ROOT}/scripts/clear_pending.sh" user_input'; Timeout = 3 }
    }
    foreach ($ev in @('PermissionRequest','Stop','UserPromptSubmit','PreToolUse','PostToolUse')) {
        Assert-True ($raw.hooks.$ev[0].hooks[0].command -eq $expected[$ev].Command) ($ev + ' posix command matches the permanent literal')
        Assert-True ($raw.hooks.$ev[0].hooks[0].timeout -eq $expected[$ev].Timeout) ($ev + ' timeout matches the permanent literal')
    }
}
$RepoRoot = Split-Path -Parent (Split-Path -Parent $TestRoot)
Invoke-Case '30-question-tool-without-questions' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $pend = Join-Path $sd 'pending_s30_notification_x_1_1'
    [System.IO.File]::WriteAllText($pend, 'notification', [System.Text.Encoding]::UTF8)
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd }
    $q = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"call-0","session_id":"s30","tool_input":{"questions":[]}}'
    $code = Get-HookExit -Json $q -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code -eq 0) 'question tool with no questions exits 0'
    Assert-True (Test-Path -LiteralPath $pend) 'empty question list preserves pending (posix parity)'
    $code2 = Get-HookExit -Json '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s30"}' -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code2 -eq 0) 'ordinary tool exits 0'
    Assert-True (-not (Test-Path -LiteralPath $pend)) 'ordinary tool clears pending'
}
$Installer = Join-Path (Join-Path $RepoRoot 'install') 'codex.ps1'
function Invoke-Installer {
    param([string]$CodexHome)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Installer + '" -NonInteractive'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(60000) | Out-Null
    return @{ Code = $p.ExitCode; Out = $out }
}

# Interactive install: the installer's channel quick-enable prompt reads stdin,
# which is how the notify.json rewrite path is exercised deterministically.
function Invoke-InstallerWithInput {
    param([string]$CodexHome, [string]$InputText = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Installer + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($InputText)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(60000) | Out-Null
    return @{ Code = $p.ExitCode; Out = $out }
}
Invoke-Case 'A-install-fresh' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $ch 'codex-push-hooks') 'scripts') 'windows/CodexPushHooks.psm1')) 'runtime copied'
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $ch 'codex-push-hooks') 'notify.json')) 'config created'
    $hj = Get-Content (Join-Path $ch 'hooks.json') -Raw | ConvertFrom-Json
    Assert-True ($hj.hooks.PermissionRequest[0].hooks[0].commandWindows -match 'powershell\.exe') 'hooks written'
}
Invoke-Case 'B-install-preserve-unrelated' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'; New-Item -ItemType Directory -Force -Path $ch | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ch 'hooks.json'), '{"hooks":{"MyCustom":[{"matcher":"*","hooks":[{"type":"command","command":"echo hi","timeout":3}]}]}}', [System.Text.Encoding]::UTF8)
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    $hj = Get-Content (Join-Path $ch 'hooks.json') -Raw | ConvertFrom-Json
    Assert-True ($hj.hooks.MyCustom[0].hooks[0].command -eq 'echo hi') 'unrelated preserved'
    Assert-True ($null -ne $hj.hooks.PermissionRequest[0].hooks[0].commandWindows) 'ours added'
}
Invoke-Case 'C-install-invalid-hooks' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'; New-Item -ItemType Directory -Force -Path $ch | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ch 'hooks.json'), 'NOT JSON{{{', [System.Text.Encoding]::UTF8)
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -ne 0) 'installer fails safely'
    Assert-True ((Get-Content (Join-Path $ch 'hooks.json') -Raw) -eq 'NOT JSON{{{') 'original unchanged'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ch 'codex-push-hooks'))) 'preflight failed before creating the install dir'
    Assert-True (@(Get-ChildItem -LiteralPath $ch -Filter 'hooks.json.backup.*' -ErrorAction SilentlyContinue).Count -eq 0) 'preflight wrote no backup'
}
Invoke-Case 'D-install-keep-canonical' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $cd = Join-Path (Join-Path $ch 'codex-push-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cd) | Out-Null
    [System.IO.File]::WriteAllText($cd, '{"channels":{},"marker":"keep-me"}', [System.Text.Encoding]::UTF8)
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    Assert-True ((Get-Content $cd -Raw) -match 'keep-me') 'canonical not overwritten'
}
Invoke-Case 'E-install-legacy-reuse' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $leg = Join-Path (Join-Path $ch 'cc-notify-hooks') 'notify.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $leg) | Out-Null
    [System.IO.File]::WriteAllText($leg, '{"channels":{},"marker":"legacy-kept"}', [System.Text.Encoding]::UTF8)
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    $canon = Join-Path (Join-Path $ch 'codex-push-hooks') 'notify.json'
    Assert-True ((Get-Content $canon -Raw) -match 'legacy-kept') 'legacy reused'
    Assert-True (Test-Path -LiteralPath $leg) 'legacy file preserved'
}
Invoke-Case 'F-install-spaced-codex-home' {
    $d = New-CaseDir; $ch = Join-Path $d 'my codex home'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0 with spaces'
    Assert-True (Test-Path -LiteralPath (Join-Path $ch 'hooks.json')) 'hooks in spaced home'
    $hj = Get-Content (Join-Path $ch 'hooks.json') -Raw | ConvertFrom-Json
    $cmd = [string]$hj.hooks.PermissionRequest[0].hooks[0].commandWindows
    Assert-True (-not $cmd.Contains('"')) 'generated command line has no double quote'
    $decoded = Get-DecodedHookCommand -Cmd $cmd
    Assert-True ($decoded -match 'my codex home') 'spaced path is embedded in the payload'
    Assert-True ($decoded -match 'hook\.ps1') 'payload targets the installed hook'
}
Invoke-Case 'G-install-spaced-repo-source' {
    $text = [System.IO.File]::ReadAllText($Installer, [System.Text.Encoding]::UTF8)
    Assert-True ($text -match 'plugins/codex-push-hooks') 'installer sources the real plugin dir'
    Assert-True ($text -notmatch '"\$repoRoot/scripts"') 'no root-symlink script path'
    $d = New-CaseDir; $ch = Join-Path $d 'home with interior spaces'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'quoted paths survive spaces'
}
Invoke-Case 'H-install-plain-file-links' {
    $rootScripts = Join-Path $RepoRoot 'scripts'
    Assert-True (Test-Path -LiteralPath $rootScripts -PathType Leaf) 'root scripts entry is a plain file (materialized link)'
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer works without symlink privilege'
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $ch 'codex-push-hooks') 'scripts') 'windows/hook.ps1')) 'windows entry point installed'
}
Invoke-Case '31-installer-runner-spaced-codex-home' {
    # The installer-generated commandWindows must also survive the current Codex
    # runner with a CODEX_HOME that contains spaces, and must not depend on
    # PLUGIN_ROOT (standalone installs carry their own absolute path).
    $d = New-CaseDir; $ch = Join-Path $d 'codex home with spaces'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    $hj = Get-Content (Join-Path $ch 'hooks.json') -Raw | ConvertFrom-Json
    $cmdLine = [string]$hj.hooks.PermissionRequest[0].hooks[0].commandWindows
    Assert-True (-not $cmdLine.Contains('"')) 'installed command line has no double quote'
    $fixture = '{"hook_event_name":"PermissionRequest","prompt":"standalone spaced home","cwd":"C:/w/proj","session_id":"s31"}'
    $res = Invoke-CmdWrappedCommand -CmdLine $cmdLine -StdIn $fixture -ExtraEnv @{ CC_NOTIFY_RENDER_ONLY = '1'; PLUGIN_ROOT = '' }
    Assert-True ($res['Code'] -eq 0) 'standalone runner exit 0'
    Assert-True ($res['Out'] -match 'standalone spaced home') 'standalone runner reached the installed hook.ps1'
}
Invoke-Case '32-installer-hooks-json-without-bom' {
    # Windows PowerShell 5.1 writes a UTF-8 BOM with Out-File -Encoding utf8;
    # Codex parses hooks.json as text, so the BOM must never be emitted.
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $r = Invoke-Installer -CodexHome $ch
    Assert-True ($r['Code'] -eq 0) 'installer exit 0'
    $hooksFile = Join-Path $ch 'hooks.json'
    $bytes = Get-FirstBytes -Path $hooksFile
    Assert-True ($bytes[0] -eq 0x7B) 'fresh hooks.json starts with a JSON brace'
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'fresh hooks.json has no UTF-8 BOM'
    Assert-True ($null -ne ((Get-Content $hooksFile -Raw) | ConvertFrom-Json)) 'fresh hooks.json parses'
    $r2 = Invoke-Installer -CodexHome $ch
    Assert-True ($r2['Code'] -eq 0) 'second install exit 0 (merge path)'
    $bytes2 = Get-FirstBytes -Path $hooksFile
    Assert-True ($bytes2[0] -eq 0x7B) 'merged hooks.json starts with a JSON brace'
    Assert-True (-not ($bytes2[0] -eq 0xEF -and $bytes2[1] -eq 0xBB -and $bytes2[2] -eq 0xBF)) 'merged hooks.json has no UTF-8 BOM'
    Assert-True ($null -ne ((Get-Content $hooksFile -Raw) | ConvertFrom-Json)) 'merged hooks.json parses'
}
Invoke-Case '33-installer-quick-enable-without-bom' {
    $d = New-CaseDir; $ch = Join-Path $d 'codex'
    $r = Invoke-InstallerWithInput -CodexHome $ch -InputText ('1' + [char]10)
    Assert-True ($r['Code'] -eq 0) 'interactive installer exit 0'
    $cfg = Join-Path (Join-Path $ch 'codex-push-hooks') 'notify.json'
    Assert-True (Test-Path -LiteralPath $cfg) 'notify.json written'
    $bytes = Get-FirstBytes -Path $cfg
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'rewritten notify.json has no UTF-8 BOM'
    $obj = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ($obj.channels.telegram.enabled -eq $true) 'quick-enable rewrote notify.json (telegram enabled)'
}
Invoke-Case '34-capture-records-never-contain-credentials' {
    # CC_NOTIFY_CAPTURE_DIR is a deterministic test facility: it must record the
    # request shape without ever persisting tokens or webhook URLs.
    $d = New-CaseDir
    $cap = Join-Path $d 'capture'; New-Item -ItemType Directory -Force -Path $cap | Out-Null
    $body = '{"channels":{"telegram":{"enabled":true,"bot_token":"SECRET_TELEGRAM_TOKEN_DO_NOT_WRITE","chat_id":"SECRET_CHAT_DO_NOT_WRITE"},"wechat":{"enabled":true,"webhook":"https://qyapi.invalid/cgi-bin/webhook/send?key=SECRET_WEBHOOK_DO_NOT_WRITE"},"pushover":{"enabled":true,"app_token":"SECRET_PUSHOVER_TOKEN_DO_NOT_WRITE","user_key":"SECRET_PUSHOVER_USER_DO_NOT_WRITE"},"gotify":{"enabled":true,"server":"https://gotify.invalid","app_token":"SECRET_GOTIFY_TOKEN_DO_NOT_WRITE"}},"rate_limit":10}'
    $cfg = Write-TestConfig -Dir $d -Body $body
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"Stop","last_assistant_message":"done","cwd":"C:/w/p","session_id":"s34"}'
    $c = Get-CphNotificationContent -Event $e -EventType 'stop' -EventKind 'stop'
    $env:CC_NOTIFY_CAPTURE_DIR = $cap
    foreach ($ch in @('telegram','wechat','pushover','gotify')) {
        $cc = Get-CphChannelConfig -ConfigPath $cfg -Channel $ch
        $req = New-CphChannelRequest -Channel $ch -Title $c['Title'] -Body $c['Body'] -ChannelConfig $cc -Content $c
        Assert-True ($null -ne $req) ($ch + ' request is built in memory with credentials')
        Assert-True ((Invoke-CphChannelSend -Channel $ch -Title $c['Title'] -Body $c['Body'] -ChannelConfig $cc -Content $c) -eq $true) ($ch + ' captured send')
    }
    $files = @(Get-ChildItem -LiteralPath $cap -Filter '*.json')
    Assert-True ($files.Count -eq 4) 'four capture records'
    $sentinels = @('SECRET_TELEGRAM_TOKEN_DO_NOT_WRITE','SECRET_CHAT_DO_NOT_WRITE','SECRET_WEBHOOK_DO_NOT_WRITE','SECRET_PUSHOVER_TOKEN_DO_NOT_WRITE','SECRET_PUSHOVER_USER_DO_NOT_WRITE','SECRET_GOTIFY_TOKEN_DO_NOT_WRITE')
    foreach ($f in $files) {
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        foreach ($s in $sentinels) { Assert-True (-not $text.Contains($s)) ('capture ' + $f.Name + ' must not contain ' + $s) }
        Assert-True (-not $text.Contains('https://')) ('capture ' + $f.Name + ' must not contain a destination url')
        Assert-True (-not $text.Contains('SECRET_')) ('capture ' + $f.Name + ' must not contain any sentinel secret')
        $capObj = $text | ConvertFrom-Json
        $names = @($capObj.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-True ($names.Count -eq 6) ('capture ' + $f.Name + ' has exactly the six safe fields')
        foreach ($name in $names) {
            Assert-True (@('channel','method','captured','body_kind','url_scheme','field_keys') -contains $name) ('capture ' + $f.Name + ' has an unexpected field: ' + $name)
        }
        Assert-True ($capObj.captured -eq $true) ('capture ' + $f.Name + ' records the captured marker')
        Assert-True ($capObj.url_scheme -eq 'https') ('capture ' + $f.Name + ' records only the url scheme')
    }
    $tg = @($files | Where-Object { $_.Name -like 'telegram_*' })[0]
    $tgObj = [System.IO.File]::ReadAllText($tg.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True (($tgObj.field_keys -contains 'chat_id') -and ($tgObj.field_keys -contains 'text')) 'telegram field keys recorded without values'
}
Invoke-Case '35-worker-launch-failure-cleanup' {
    # A non-executable file named powershell.exe first on PATH makes the hook's
    # Start-Process worker launch fail deterministically; the hook must stay
    # fail-open and leave no orphaned job file or pending marker behind.
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{"telegram":{"enabled":true,"delay":5,"bot_token":"T","chat_id":"C"}},"rate_limit":10}'
    $shadow = Join-Path $d 'shadow'; New-Item -ItemType Directory -Force -Path $shadow | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shadow 'powershell.exe'), 'not a real executable', [System.Text.Encoding]::ASCII)
    $hook = Join-Path (Join-Path (Join-Path $TestRoot 'scripts') 'windows') 'hook.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hook + '" notification'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CC_NOTIFY_CONFIG'] = $cfg
    $psi.EnvironmentVariables['CC_NOTIFY_STATE_DIR'] = $sd
    $psi.EnvironmentVariables['PATH'] = ($shadow + ';' + $env:PATH)
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write('{"hook_event_name":"PermissionRequest","prompt":"launch fails","cwd":"C:/w/p","session_id":"s35"}')
    $p.StandardInput.Close()
    $p.StandardOutput.ReadToEnd() | Out-Null
    $p.WaitForExit(30000) | Out-Null
    Assert-True ($p.ExitCode -eq 0) 'hook still exits 0 when the worker cannot start'
    Assert-True (@(Get-ChildItem -LiteralPath $sd -Filter 'job_*.json' -ErrorAction SilentlyContinue).Count -eq 0) 'job file cleaned up after launch failure'
    Assert-True (@(Get-ChildItem -LiteralPath $sd -Filter 'pending_*' -ErrorAction SilentlyContinue).Count -eq 0) 'pending marker cleaned up after launch failure'
}
Invoke-Case '36-request-user-input-async-render' {
    # The current Codex async question tool carries a title-only schema
    # (questions[0].title + string options) instead of header + question.
    $raw = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-call-1","session_id":"async-session","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Which environment should I use?","options":["Staging","Production"]}]}}'
    $e = ConvertFrom-CphHookJson -RawJson $raw
    Assert-True ($e['QuestionCount'] -eq 1) 'async question count'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'user_input'
    Assert-True ($c['Title'] -match 'Reply needed') 'async reply title'
    Assert-True ($c['EventKind'] -eq 'user_input') 'async event kind'
    Assert-True ($c['SummaryShort'] -eq 'Which environment should I use?') 'async title becomes the summary'
    Assert-True ($c['OptionLabels'].Count -eq 2) 'async option label count'
    Assert-True ($c['OptionLabels'][0] -eq 'Staging' -and $c['OptionLabels'][1] -eq 'Production') 'async option labels stay in order'
    Assert-True ($c['EventObject']['question_count'] -eq 1) 'async event question_count'
    Assert-True ($c['Body'] -match 'Questions: 1') 'async question count in body'
    Assert-True ($c['Body'] -match 'Session async-se') 'async short session in body'
}
Invoke-Case '37-async-pending-survives-until-user-prompt-submit' {
    # Direct scope: PreToolUse(request_user_input_async) creates the pending state
    # and a later UserPromptSubmit clears it. This case does not execute a Codex
    # tool completion; case 39 proves the PostToolUse matcher does not select the
    # async tool, which is what keeps the marker alive in the real host.
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{}}'
    $other = Join-Path $sd 'pending_other-session_user_input_z_1_1'
    [System.IO.File]::WriteAllText($other, 'user_input', [System.Text.Encoding]::UTF8)
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd; 'CC_NOTIFY_CONFIG' = $cfg }
    $async = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-call-1","session_id":"async-session","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Which environment should I use?","options":["Staging","Production"]}]}}'
    $code = Get-HookExit -Json $async -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code -eq 0) 'async pre-tool-use exits 0'
    $made = @(Get-ChildItem -LiteralPath $sd -Filter 'pending_async-session_user_input_*')
    Assert-True ($made.Count -eq 1) 'async pre-tool-use created the user_input pending marker'
    Assert-True (Test-Path -LiteralPath $made[0].FullName) 'pending survives until the later user message'
    $up = '{"hook_event_name":"UserPromptSubmit","message":"Staging","session_id":"async-session"}'
    $code2 = Get-HookExit -Json $up -Action 'clear' -ExtraEnv $extra
    Assert-True ($code2 -eq 0) 'UserPromptSubmit clear exits 0'
    Assert-True (-not (Test-Path -LiteralPath $made[0].FullName)) 'UserPromptSubmit cleared the async pending marker'
    Assert-True (Test-Path -LiteralPath $other) 'another session stays untouched'
}
Invoke-Case '38-sync-request-user-input-unchanged' {
    # The synchronous tool keeps its original lifecycle: PostToolUse clears.
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $cfg = Write-TestConfig -Dir $d -Body '{"channels":{}}'
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd; 'CC_NOTIFY_CONFIG' = $cfg }
    $sync = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"sync-call-1","session_id":"sync-session","cwd":"C:/w/project","tool_input":{"questions":[{"header":"Scope","question":"What does this fix cover?","options":[{"label":"Full fix"},{"label":"Minimal patch"}]}]}}'
    $code = Get-HookExit -Json $sync -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code -eq 0) 'sync pre-tool-use exits 0'
    $made = @(Get-ChildItem -LiteralPath $sd -Filter 'pending_sync-session_user_input_*')
    Assert-True ($made.Count -eq 1) 'sync pre-tool-use created the user_input pending marker'
    $post = '{"hook_event_name":"PostToolUse","tool_name":"request_user_input","tool_use_id":"sync-call-1","session_id":"sync-session"}'
    $code2 = Get-HookExit -Json $post -Action 'clear' -Kind 'user_input' -ExtraEnv $extra
    Assert-True ($code2 -eq 0) 'sync PostToolUse clear exits 0'
    Assert-True (-not (Test-Path -LiteralPath $made[0].FullName)) 'sync PostToolUse cleared the pending marker'
}
Invoke-Case '39-posttooluse-manifest-narrow' {
    $raw = Get-Content (Join-Path $TestRoot 'hooks/codex-hooks.json') -Raw | ConvertFrom-Json
    Assert-True ($raw.hooks.PreToolUse[0].matcher -eq '*') 'PreToolUse matcher stays * so the async question tool reaches the dispatcher'
    Assert-True ($raw.hooks.PostToolUse[0].matcher -eq '^request_user_input$') 'PostToolUse matcher stays exactly ^request_user_input$'
    Assert-True ($raw.hooks.PostToolUse[0].matcher -notmatch '_async') 'PostToolUse matcher contains no async tool name'
    Assert-True (-not ('request_user_input_async' -match $raw.hooks.PostToolUse[0].matcher)) 'request_user_input_async does NOT match the PostToolUse clear matcher'
    Assert-True ([bool]('request_user_input' -match $raw.hooks.PostToolUse[0].matcher)) 'request_user_input still matches the PostToolUse clear matcher'
}
Invoke-Case '40-async-question-tool-without-questions' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $pend = Join-Path $sd 'pending_s40_user_input_x_1_1'
    [System.IO.File]::WriteAllText($pend, 'user_input', [System.Text.Encoding]::UTF8)
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd }
    $q = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"call-0","session_id":"s40","tool_input":{"questions":[]}}'
    $code = Get-HookExit -Json $q -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code -eq 0) 'async question tool with no questions exits 0'
    Assert-True (Test-Path -LiteralPath $pend) 'empty async question list preserves pending (posix parity)'
    $code2 = Get-HookExit -Json '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s40"}' -Action 'pre-tool-use' -ExtraEnv $extra
    Assert-True ($code2 -eq 0) 'ordinary tool exits 0'
    Assert-True (-not (Test-Path -LiteralPath $pend)) 'ordinary tool still clears pending'
}
Invoke-Case '41-question-tool-compatibility-names' {
    $d = New-CaseDir; $sd = Join-Path $d 'state'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $extra = @{ 'CC_NOTIFY_STATE_DIR' = $sd }
    foreach ($name in @('ask','AskUserQuestion')) {
        $pend = Join-Path $sd 'pending_compat_user_input_x_1_1'
        [System.IO.File]::WriteAllText($pend, 'user_input', [System.Text.Encoding]::UTF8)
        $q = '{"hook_event_name":"PreToolUse","tool_name":"' + $name + '","tool_use_id":"call-compat","session_id":"compat","tool_input":{"questions":[{"header":"H","question":"Q","options":[{"label":"A"}]}]}}'
        $out = Get-HookStdout -Json $q -Action 'pre-tool-use' -ExtraEnv $extra
        Assert-True ($out.Code -eq 0) ($name + ' exits 0')
        $parsed = $out.Out | ConvertFrom-Json
        Assert-True ($parsed.event_kind -eq 'user_input') ($name + ' renders the user_input notification')
        Assert-True (Test-Path -LiteralPath $pend) ($name + ' kept the pending marker (notification path, not clear)')
        Remove-Item -LiteralPath $pend -Force
    }
}
Invoke-Case '42-async-valid-free-text-question' {
    $d = New-CaseDir
    $json = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-free","session_id":"async-free-session","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Describe the environment"}]}}'
    $e = ConvertFrom-CphHookJson -RawJson $json
    Assert-True ($e['AsyncQuestionPayloadValid'] -eq $true) 'free-text async payload is valid'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'user_input'
    Assert-True ($c['Title'] -match 'Reply needed') 'free-text async notifies'
    Assert-True ($c['OptionLabels'].Count -eq 0) 'free-text async has zero option labels'
    $code = Invoke-AsyncPreToolUse -Json $json -Dir $d
    Assert-True ($code -eq 0) 'free-text async exits 0'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $d 'state') -Filter 'pending_async-free-session_user_input_*').Count -eq 1) 'free-text async creates the pending marker'
}
Invoke-Case '43-async-invalid-object-options' {
    # Stage 3B observed real async calls with object/map options being rejected
    # by the Codex handler: this exact class must never notify.
    Assert-InvalidAsyncPayload -Name 'objopts' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-objopts","session_id":"objopts","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Which environment?","options":[{"label":"Staging"},{"label":"Production"}]}]}}'
    # Validation and rendering normalization stay separate concerns: object
    # labels still normalize for the synchronous/compat schemas.
    $e = ConvertFrom-CphHookJson -RawJson '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-objopts","session_id":"objopts","tool_input":{"questions":[{"title":"Which environment?","options":[{"label":"Staging"}]}]}}'
    Assert-True ($e['QuestionCount'] -eq 1) 'object-option async still parses for rendering'
    Assert-True ($e['OptionLabels'].Count -eq 1) 'object labels still normalize when rendering'
    Assert-True ($e['AsyncQuestionPayloadValid'] -eq $false) 'object labels alone never make the async payload valid'
}
Invoke-Case '44-async-invalid-empty-options' {
    Assert-InvalidAsyncPayload -Name 'emptyopts' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-emptyopts","session_id":"emptyopts","tool_input":{"questions":[{"title":"Which environment?","options":[]}]}}'
}
Invoke-Case '45-async-invalid-blank-title' {
    Assert-InvalidAsyncPayload -Name 'blanktitle' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-blanktitle","session_id":"blanktitle","tool_input":{"questions":[{"title":"   ","options":["A"]}]}}'
}
Invoke-Case '46-async-invalid-non-string-option' {
    Assert-InvalidAsyncPayload -Name 'nonstring' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-nonstring","session_id":"nonstring","tool_input":{"questions":[{"title":"Which environment?","options":["A",123]}]}}'
}
Invoke-Case '47-async-invalid-unknown-question-field' {
    Assert-InvalidAsyncPayload -Name 'unknownfield' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-unknownfield","session_id":"unknownfield","tool_input":{"questions":[{"title":"Question?","extra":true}]}}'
}
Invoke-Case '48-async-invalid-later-question' {
    # If ANY question is invalid the runtime rejects the whole argument object.
    Assert-InvalidAsyncPayload -Name 'laterinvalid' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-laterinvalid","session_id":"laterinvalid","tool_input":{"questions":[{"title":"First?","options":["A"]},{"title":"  "}]}}'
}
Invoke-Case '49-async-valid-multi-question' {
    $d = New-CaseDir
    $json = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-multi","session_id":"async-multi-session","cwd":"C:/w/project","tool_input":{"questions":[{"title":"First?","options":["A","B"]},{"title":"Second?"}]}}'
    $e = ConvertFrom-CphHookJson -RawJson $json
    Assert-True ($e['AsyncQuestionPayloadValid'] -eq $true) 'multi-question async payload is valid'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'user_input'
    Assert-True ($c['QuestionCount'] -eq 2) 'multi-question async question count'
    Assert-True ($c['OptionLabels'].Count -eq 2) 'multi-question async first-question labels'
    $code = Invoke-AsyncPreToolUse -Json $json -Dir $d
    Assert-True ($code -eq 0) 'multi-question async exits 0'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $d 'state') -Filter 'pending_async-multi-session_user_input_*').Count -eq 1) 'multi-question async creates the pending marker'
}
Invoke-Case '50-async-invalid-root-extra-field' {
    # The handler's top-level args struct denies unknown fields too: only
    # "questions" may appear beside it, so a valid question list plus a root
    # extra field is rejected after PreToolUse and must never notify.
    Assert-InvalidAsyncPayload -Name 'rootextra' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-root-extra","session_id":"rootextra","tool_input":{"questions":[{"title":"Question?"}],"extra":true}}'
    Assert-InvalidAsyncPayload -Name 'toolinputnotobject' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-ti-array","session_id":"toolinputnotobject","tool_input":["questions"]}'
    Assert-InvalidAsyncPayload -Name 'toolinputstring' -Json '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-ti-string","session_id":"toolinputstring","tool_input":"questions"}'
}
Invoke-Case '51-async-valid-explicit-null-options' {
    # The handler models options as Option<Vec<String>>: an explicit null is
    # valid and behaves like options omitted.
    $d = New-CaseDir
    $json = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"async-nullopts","session_id":"async-null-session","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Describe the environment","options":null}]}}'
    $e = ConvertFrom-CphHookJson -RawJson $json
    Assert-True ($e['AsyncQuestionPayloadValid'] -eq $true) 'explicit null options are a valid async payload'
    $c = Get-CphNotificationContent -Event $e -EventType 'notification' -EventKind 'user_input'
    Assert-True ($c['Title'] -match 'Reply needed') 'explicit null options still notify'
    Assert-True ($c['OptionLabels'].Count -eq 0) 'explicit null options yield zero option labels'
    $code = Invoke-AsyncPreToolUse -Json $json -Dir $d
    Assert-True ($code -eq 0) 'explicit null options exit 0'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $d 'state') -Filter 'pending_async-null-session_user_input_*').Count -eq 1) 'explicit null options create the pending marker'
}
Invoke-Case '52-async-ordinary-tool-keeps-awaiting' {
    # Sequence: valid async question, then an unrelated tool call (the real
    # Stage 3B lifecycle used clock.sleep). Ordinary tool activity is not a user
    # answer, so the Reply-needed delivery pending must survive it.
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    $async = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"call-52","session_id":"s52","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Which environment should I use?","options":["Staging","Production"]}]}}'
    $code = Get-HookExit -Json $async -Action 'pre-tool-use' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'async question exits 0'
    $pend = @(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s52_user_input_*')
    Assert-True ($pend.Count -eq 1) 'async question creates the delivery pending'
    Assert-True (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's52') 'async question starts awaiting state'
    [System.IO.File]::WriteAllText((Join-Path $env.StateDir 'pending_s52_notification_x_1_1'), 'notification', [System.Text.Encoding]::UTF8)
    $code2 = Get-HookExit -Json '{"hook_event_name":"PreToolUse","tool_name":"sleep","session_id":"s52","tool_input":{"duration_ms":600000}}' -Action 'pre-tool-use' -ExtraEnv $env.Extra
    Assert-True ($code2 -eq 0) 'ordinary tool exits 0'
    Assert-True (Test-Path -LiteralPath $pend[0].FullName) 'ordinary tool activity keeps the async user_input pending'
    Assert-True (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's52') 'ordinary tool activity keeps awaiting state'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env.StateDir 'pending_s52_notification_x_1_1'))) 'ordinary tool activity still clears other pending kinds'
}
Invoke-Case '53-async-stop-suppressed-while-awaiting' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's53' -ToolUseKey 'call-53'
    $code = Get-HookExit -Json '{"hook_event_name":"Stop","session_id":"s53"}' -Action 'stop' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'suppressed stop exits 0'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s53_stop_*' -ErrorAction SilentlyContinue).Count -eq 0) 'no stop pending while awaiting'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'job_*.json' -ErrorAction SilentlyContinue).Count -eq 0) 'no stop job while awaiting'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env.StateDir 'last_s53_stop'))) 'no stop rate marker while awaiting'
    Assert-True (Test-Path -LiteralPath (Join-Path $env.StateDir 'pending_s53_user_input_call-53_1_1')) 'reply-needed pending survives Stop'
    Assert-True (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's53') 'awaiting state survives Stop'
}
Invoke-Case '54-async-userpromptsubmit-clears-and-stop-recovers' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's54' -ToolUseKey 'call-54'
    $code = Get-HookExit -Json '{"hook_event_name":"UserPromptSubmit","message":"Staging","session_id":"s54"}' -Action 'clear' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'UserPromptSubmit exits 0'
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's54')) 'UserPromptSubmit ends awaiting state'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s54_user_input_*' -ErrorAction SilentlyContinue).Count -eq 0) 'UserPromptSubmit clears the delivery pending'
    $code2 = Get-HookExit -Json '{"hook_event_name":"Stop","session_id":"s54"}' -Action 'stop' -ExtraEnv $env.Extra
    Assert-True ($code2 -eq 0) 'later stop exits 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $env.StateDir 'last_s54_stop')) 'later Stop follows the normal path again'
}
Invoke-Case '55-async-delivery-completion-is-not-the-answer' {
    # The worker removes the delivery pending after sending, but the session is
    # still waiting for the answer: awaiting state must outlive it.
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's55' -ToolUseKey 'call-55'
    Remove-Item -LiteralPath (Join-Path $env.StateDir 'pending_s55_user_input_call-55_1_1') -Force
    Assert-True (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's55') 'awaiting survives the delivery completion'
    [void](Get-HookExit -Json '{"hook_event_name":"Stop","session_id":"s55"}' -Action 'stop' -ExtraEnv $env.Extra)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env.StateDir 'last_s55_stop'))) 'Stop stays suppressed after the delivery'
    [void](Get-HookExit -Json '{"hook_event_name":"UserPromptSubmit","message":"Staging","session_id":"s55"}' -Action 'clear' -ExtraEnv $env.Extra)
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's55')) 'the real answer ends awaiting state'
}
Invoke-Case '56-async-other-notification-coexists' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's56' -ToolUseKey 'call-56'
    $code = Get-HookExit -Json '{"hook_event_name":"PermissionRequest","prompt":"allow?","session_id":"s56","cwd":"C:/w/project"}' -Action 'notification' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'PermissionRequest exits 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $env.StateDir 'pending_s56_user_input_call-56_1_1')) 'async user_input pending preserved'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s56_notification_*').Count -eq 1) 'the other notification gets its own pending'
    Assert-True (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's56') 'awaiting preserved'
}
Invoke-Case '57-async-second-question-supersedes' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's57' -ToolUseKey 'call-q1'
    $async2 = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"call-q2","session_id":"s57","cwd":"C:/w/project","tool_input":{"questions":[{"title":"Second question?","options":["A","B"]}]}}'
    $code = Get-HookExit -Json $async2 -Action 'pre-tool-use' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'second async question exits 0'
    $awaiting = @(Get-ChildItem -LiteralPath $env.StateDir -Filter 'awaiting_async_s57_*')
    Assert-True ($awaiting.Count -eq 1) 'exactly one canonical awaiting marker'
    Assert-True ($awaiting[0].Name -like '*call-q2*') 'the newer question is canonical'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s57_user_input_*').Count -eq 1) 'exactly one user_input delivery pending'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s57_user_input_*')[0].Name -like '*call-q2*') 'the newer delivery is active'
}
Invoke-Case '58-async-invalid-creates-no-awaiting' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    [System.IO.File]::WriteAllText((Join-Path $env.StateDir 'pending_s58_user_input_old_1_1'), 'user_input', [System.Text.Encoding]::UTF8)
    $invalid = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_use_id":"call-bad","session_id":"s58","tool_input":{"questions":[{"title":"Which?","options":[{"label":"A"}]}]}}'
    $code = Get-HookExit -Json $invalid -Action 'pre-tool-use' -ExtraEnv $env.Extra
    Assert-True ($code -eq 0) 'invalid async exits 0'
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's58')) 'invalid async creates no awaiting state'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s58_user_input_call-bad*' -ErrorAction SilentlyContinue).Count -eq 0) 'invalid async creates no pending'
    Assert-True (Test-Path -LiteralPath (Join-Path $env.StateDir 'pending_s58_user_input_old_1_1')) 'invalid async clears nothing'
}
Invoke-Case '59-sync-question-keeps-classic-lifecycle' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    $sync = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"call-sync","session_id":"s59","cwd":"C:/w/project","tool_input":{"questions":[{"header":"Scope","question":"What does this fix cover?","options":[{"label":"Full"}]}]}}'
    [void](Get-HookExit -Json $sync -Action 'pre-tool-use' -ExtraEnv $env.Extra)
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's59')) 'sync question creates no awaiting state'
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s59_user_input_*').Count -eq 1) 'sync question creates its delivery pending'
    [void](Get-HookExit -Json '{"hook_event_name":"PostToolUse","tool_name":"request_user_input","tool_use_id":"call-sync","session_id":"s59"}' -Action 'clear' -Kind 'user_input' -ExtraEnv $env.Extra)
    Assert-True (@(Get-ChildItem -LiteralPath $env.StateDir -Filter 'pending_s59_user_input_*' -ErrorAction SilentlyContinue).Count -eq 0) 'sync PostToolUse still clears'
}
Invoke-Case '60-sync-question-supersedes-async-wait' {
    $d = New-CaseDir; $env = New-AsyncCaseEnv -Dir $d
    Add-AsyncAwaitingFixture -StateDir $env.StateDir -SessionKey 's60' -ToolUseKey 'call-async60'
    $sync = '{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"call-sync60","session_id":"s60","cwd":"C:/w/project","tool_input":{"questions":[{"header":"H","question":"Q?","options":[{"label":"A"}]}]}}'
    [void](Get-HookExit -Json $sync -Action 'pre-tool-use' -ExtraEnv $env.Extra)
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's60')) 'a sync question supersedes the async wait'
    [void](Get-HookExit -Json '{"hook_event_name":"PostToolUse","tool_name":"request_user_input","tool_use_id":"call-sync60","session_id":"s60"}' -Action 'clear' -Kind 'user_input' -ExtraEnv $env.Extra)
    Assert-True (-not (Test-CphAsyncAwaiting -StateDir $env.StateDir -SessionKey 's60')) 'no stale awaiting marker after the sync transition'
    [void](Get-HookExit -Json '{"hook_event_name":"Stop","session_id":"s60"}' -Action 'stop' -ExtraEnv $env.Extra)
    Assert-True (Test-Path -LiteralPath (Join-Path $env.StateDir 'last_s60_stop')) 'Stop is not suppressed after the sync transition'
}
Write-Output ''
Write-Output ('PSVersion=' + [string]$PSVersionTable.PSVersion)
try { Write-Output ('OS=' + [string][System.Environment]::OSVersion.VersionString) } catch { }
try {
    $pp = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    Write-Output ('powershell.exe=' + [string]$pp)
} catch { }
try {
    $pw = (& where.exe pwsh 2>$null | Select-Object -First 1)
    Write-Output ('pwsh=' + [string]$pw)
} catch { Write-Output 'pwsh=not-found' }
Write-Output ('PASSED=' + $script:Passed + ' FAILED=' + $script:Failed)
if ($script:Failed -gt 0) { Write-Output ('FAILURES=' + ($script:Failures -join ',')) }
Restore-SavedEnv
if ($script:Failed -gt 0) { exit 1 }
exit 0
