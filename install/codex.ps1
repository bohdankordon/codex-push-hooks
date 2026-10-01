# codex-push-hooks standalone Windows installer (Codex CLI branch).
# Native PowerShell: no Bash, no jq, no curl, no WSL, no admin, no symlinks.
# Installs the Windows runtime from plugins/codex-push-hooks/ (the real
# plugin directory; repository-root symlinks are never used) into
# <CODEX_HOME>/codex-push-hooks/ and merges Windows hook commands into
# <CODEX_HOME>/hooks.json.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install/codex.ps1
#   powershell -ExecutionPolicy Bypass -File install/codex.ps1 -NonInteractive
# CODEX_HOME may point at a custom directory for testing or portable setups.
param([switch]$NonInteractive)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host $m }
function Write-Ok { param([string]$m) Write-Host ("  [OK] " + $m) }
function Write-WarnMsg { param([string]$m) Write-Host ("  [WARN] " + $m) }
function Write-ErrMsg { param([string]$m) Write-Host ("  [ERROR] " + $m) }

# Windows PowerShell 5.1's "Out-File -Encoding utf8" always emits a UTF-8 BOM,
# and Codex reads hooks.json as text without stripping one, so every JSON file
# written here goes through an explicit BOM-less encoder.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# Quote-safe Windows hook launcher. The whole bootstrap travels as a UTF-16LE
# base64 -EncodedCommand payload, so the emitted command line contains no double
# quote character at all and cannot be misparsed by the Codex hook runner's
# cmd.exe /C "<command line>" wrapping. It is equally valid when the runner uses
# a PowerShell-family outer shell, because base64 has no shell metacharacters.
function ConvertTo-EncodedHookCommand {
    param([string]$ScriptText)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
    return ('powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
}

function Get-HomeDir {
    if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE)) { return $env:USERPROFILE }
    if ($env:HOME -and (Test-Path -LiteralPath $env:HOME)) { return $env:HOME }
    try { $p = [Environment]::GetFolderPath('UserProfile'); if ($p) { return $p } } catch { }
    return $env:USERPROFILE
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$pluginSrc = Join-Path $repoRoot 'plugins/codex-push-hooks'
$winSrc = Join-Path (Join-Path (Join-Path $pluginSrc 'scripts') 'windows') 'CodexPushHooks.psm1'
if (-not (Test-Path -LiteralPath $winSrc -PathType Leaf)) {
    Write-ErrMsg ('Windows runtime not found: ' + $winSrc)
    Write-ErrMsg 'Run this installer from a full repository checkout (plugins/codex-push-hooks must exist).'
    exit 1
}

$homeDir = Get-HomeDir
$codexHome = $env:CODEX_HOME
if ([string]::IsNullOrEmpty($codexHome)) { $codexHome = Join-Path $homeDir '.codex' }
$installDir = Join-Path $codexHome 'codex-push-hooks'
$scriptsDir = Join-Path $installDir 'scripts'
$configFile = Join-Path $installDir 'notify.json'
$hooksFile = Join-Path $codexHome 'hooks.json'
$codexConfig = Join-Path $codexHome 'config.toml'
$legacyConfig = Join-Path (Join-Path $codexHome 'cc-notify-hooks') 'notify.json'

# Preflight: an existing hooks.json that cannot be parsed must fail here, before
# the installer creates or rewrites the configuration or the runtime.
$existingHooks = $null
if (Test-Path -LiteralPath $hooksFile -PathType Leaf) {
    try {
        $rawHooks = [System.IO.File]::ReadAllText($hooksFile, [System.Text.Encoding]::UTF8)
        $existingHooks = $rawHooks | ConvertFrom-Json
    } catch { $existingHooks = $null }
    if ($null -eq $existingHooks) {
        Write-ErrMsg ('hooks.json exists but cannot be parsed: ' + $hooksFile)
        Write-ErrMsg 'Nothing was changed. Fix or remove the file, then run the installer again.'
        exit 1
    }
}

Write-Info '========================================='
Write-Info '  codex-push-hooks - Codex CLI Windows install'
Write-Info ('  CODEX_HOME: ' + $codexHome)
Write-Info '========================================='
Write-Info ''

Write-Info '[1/4] configuring push channels...'
$exampleFile = Join-Path (Join-Path $pluginSrc 'config') 'notify.example.json'
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    if ((Test-Path -LiteralPath $legacyConfig -PathType Leaf)) {
        $reuse = $false
        if ($NonInteractive) { $reuse = $true }
        else {
            Write-Info ('  Detected legacy configuration: ' + $legacyConfig)
            $ans = Read-Host '  Reuse it (copied, original kept)? [Y/n]'
            if ([string]::IsNullOrEmpty($ans) -or $ans -match '^[Yy]') { $reuse = $true }
        }
        if ($reuse) {
            New-Item -ItemType Directory -Force -Path $installDir | Out-Null
            Copy-Item -LiteralPath $legacyConfig -Destination $configFile -Force
            Write-Ok 'reused the legacy configuration (the original file was kept)'
        }
    }
}
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $exampleFile -PathType Leaf)) {
        Write-ErrMsg ('configuration template not found: ' + $exampleFile)
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -LiteralPath $exampleFile -Destination $configFile -Force
    Write-Ok ('created a default configuration: ' + $configFile)
    Write-Info '  Edit it to enable channels and fill in credentials.'
} else {
    Write-Ok ('kept the existing configuration: ' + $configFile)
}
if (-not $NonInteractive) {
    Write-Info ''
    Write-Info '  Channel quick-enable (optional): enter numbers to enable, Enter to skip.'
    Write-Info '  1=telegram 2=bark 3=pushover 4=ntfy 5=gotify 6=wechat 7=feishu 8=dingtalk 9=slack 10=discord'
    $sel = Read-Host '  Choose'
    if (-not [string]::IsNullOrEmpty($sel)) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            $names = @('telegram','bark','pushover','ntfy','gotify','wechat','feishu','dingtalk','slack','discord')
            $idx = 1
            foreach ($n in $names) {
                if ((',' + $sel + ',') -match ('[^0-9]' + $idx + '[^0-9]') -or $sel -eq [string]$idx) {
                    if ($cfg.channels -and $cfg.channels.PSObject.Properties[$n]) {
                        $cfg.channels.$n.enabled = $true
                    }
                }
                $idx++
            }
            Write-Utf8NoBom -Path $configFile -Text ($cfg | ConvertTo-Json -Depth 10)
            Write-Ok 'channel selection saved (fill in credentials in notify.json)'
        } catch { Write-WarnMsg 'could not update channel selection; edit notify.json manually.' }
    }
}
Write-Info ''
Write-Info '[2/4] installing the Windows runtime...'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
$srcScripts = Join-Path $pluginSrc 'scripts'
Copy-Item -Path (Join-Path $srcScripts '*') -Destination $scriptsDir -Recurse -Force
Write-Ok ('runtime copied to ' + $scriptsDir)
Write-Info ''
Write-Info '[3/4] writing hooks.json...'
$hookBase = Join-Path (Join-Path $scriptsDir 'windows') 'hook.ps1'
function New-HookCommand {
    param([string]$PosixScript, [string]$PosixArgs, [string]$WinArgs)
    $posix = 'bash "' + (Join-Path $scriptsDir $PosixScript).Replace('\', '/') + '"'
    if ($PosixArgs -ne '') { $posix = $posix + ' ' + $PosixArgs }
    # The absolute installed hook path is baked into the encoded bootstrap, and
    # a path containing a single quote is doubled so the PowerShell literal
    # survives any CODEX_HOME (spaces included) without an outer quote pair.
    $escapedHook = $hookBase.Replace("'", "''")
    $bootstrap = '$ErrorActionPreference=''SilentlyContinue'';$h=''' + $escapedHook + ''';if(Test-Path -LiteralPath $h){& $h ' + $WinArgs + '}'
    $win = ConvertTo-EncodedHookCommand -ScriptText $bootstrap
    return @{ command = $posix; commandWindows = $win }
}
$cNotif = New-HookCommand -PosixScript 'notify.sh' -PosixArgs 'notification' -WinArgs "'notification'"
$cStop = New-HookCommand -PosixScript 'notify.sh' -PosixArgs 'stop' -WinArgs "'stop'"
$cClear = New-HookCommand -PosixScript 'clear_pending.sh' -PosixArgs '' -WinArgs "'clear'"
$cPre = New-HookCommand -PosixScript 'pre_tool_use.sh' -PosixArgs '' -WinArgs "'pre-tool-use'"
$cClearUi = New-HookCommand -PosixScript 'clear_pending.sh' -PosixArgs 'user_input' -WinArgs "'clear' 'user_input'"
$desired = @{}
$desired['PermissionRequest'] = @(@{ matcher = '*'; hooks = @(@{ type = 'command'; command = $cNotif['command']; commandWindows = $cNotif['commandWindows']; timeout = 5 }) })
$desired['Stop'] = @(@{ matcher = '*'; hooks = @(@{ type = 'command'; command = $cStop['command']; commandWindows = $cStop['commandWindows']; timeout = 5 }) })
$desired['UserPromptSubmit'] = @(@{ matcher = '*'; hooks = @(@{ type = 'command'; command = $cClear['command']; commandWindows = $cClear['commandWindows']; timeout = 3 }) })
$desired['PreToolUse'] = @(@{ matcher = '*'; hooks = @(@{ type = 'command'; command = $cPre['command']; commandWindows = $cPre['commandWindows']; timeout = 3 }) })
$desired['PostToolUse'] = @(@{ matcher = '^request_user_input$'; hooks = @(@{ type = 'command'; command = $cClearUi['command']; commandWindows = $cClearUi['commandWindows']; timeout = 3 }) })
$existing = $existingHooks
if ($null -eq $existing) { $existing = New-Object PSObject }
if (-not $existing.PSObject.Properties['hooks']) {
    $existing | Add-Member -NotePropertyName 'hooks' -NotePropertyValue (New-Object PSObject)
}
foreach ($ev in $desired.Keys) {
    if ($existing.hooks.PSObject.Properties[$ev]) { $existing.hooks.$ev = $desired[$ev] }
    else { $existing.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $desired[$ev] }
}
New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
if (Test-Path -LiteralPath $hooksFile -PathType Leaf) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backup = ($hooksFile + '.backup.' + $stamp)
    Copy-Item -LiteralPath $hooksFile -Destination $backup -Force
    Write-Info ('  backed up hooks.json to: ' + $backup)
}
$tmpHooks = ($hooksFile + '.tmp')
try {
    Write-Utf8NoBom -Path $tmpHooks -Text ($existing | ConvertTo-Json -Depth 20)
    Move-Item -LiteralPath $tmpHooks -Destination $hooksFile -Force
} catch {
    try { if (Test-Path -LiteralPath $tmpHooks) { Remove-Item -LiteralPath $tmpHooks -Force -ErrorAction SilentlyContinue } } catch { }
    Write-ErrMsg 'failed to write hooks.json; the original file was left unchanged.'
    exit 1
}
Write-Ok ('hooks written to ' + $hooksFile)
Write-Info ''
Write-Info '[4/4] checking hooks and shell...'
$hooksEnabled = $false
if (Test-Path -LiteralPath $codexConfig -PathType Leaf) {
    try {
        $m = Select-String -LiteralPath $codexConfig -Pattern '^\s*(codex_)?hooks\s*=\s*true' -Quiet
        if ($m) { $hooksEnabled = $true }
    } catch { }
}
try {
    $hits = @(& where.exe pwsh 2>$null)
    if ($hits -and $hits.Count -gt 0) {
        Write-Info ('  pwsh resolved to: ' + $hits[0])
        if ($hits[0] -match 'WindowsApps') {
            Write-WarnMsg 'the first pwsh on PATH is a Store/MSIX alias (WindowsApps). Current Codex builds may fail to spawn command hooks from that shell configuration.'
            Write-WarnMsg 'This plugin targets Windows PowerShell (powershell.exe) and does not require pwsh.'
        } else { Write-Info '  This plugin targets Windows PowerShell (powershell.exe); pwsh is not required.' }
    } else { Write-Info '  pwsh not found on PATH; that is fine (this plugin uses powershell.exe).' }
} catch { Write-Info '  pwsh check skipped.' }
Write-Info ''
Write-Info '========================================='
if ($hooksEnabled) { Write-Ok ('hooks are already enabled in ' + $codexConfig) }
else {
    Write-WarnMsg 'Important: Codex hooks must be enabled manually.'
    Write-Info ('  Add the following to ' + $codexConfig + ':')
    Write-Info ''
    Write-Info '    [features]'
    Write-Info '    hooks = true'
    Write-Info ''
    Write-Info '  Save the file; it takes effect the next time Codex starts.'
    Write-Info '  (codex_hooks = true is a deprecated alias and is still detected.)'
}
Write-Info ''
Write-Info '  Next steps:'
Write-Info '  1. Edit notify.json to enable channels and fill in credentials.'
Write-Info '  2. Restart Codex so the hooks take effect.'
Write-Info '  3. Run the Windows tests: powershell -File plugins/codex-push-hooks/test_windows.ps1'
Write-Info '========================================='
