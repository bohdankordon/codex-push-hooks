# worker.ps1 - detached delayed-delivery worker (native Windows).
# Receives only a job FILE PATH on the command line; credentials stay in
# the config file. Waits out each channel delay, re-checks the pending
# marker before every tier (a missing marker cancels the remaining tiers),
# then removes its pending marker and job file. Never blocks Codex.
param([string]$JobPath = '')

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'CodexPushHooks.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function ConvertTo-WorkerHashtable {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Node.Keys) { $h[[string]$k] = (ConvertTo-WorkerHashtable -Node $Node[$k]) }
        return $h
    }
    if ($Node -is [System.Array]) {
        $arr = @()
        foreach ($e in $Node) { $arr += (ConvertTo-WorkerHashtable -Node $e) }
        return $arr
    }
    try {
        if ($Node -is [string] -or $Node -is [ValueType]) { return $Node }
        $props = $Node.PSObject.Properties
        if ($null -ne $props) {
            $h = @{}
            foreach ($p in $props) { $h[$p.Name] = (ConvertTo-WorkerHashtable -Node $p.Value) }
            return $h
        }
    } catch { }
    return $Node
}

try {
    if ([string]::IsNullOrEmpty($JobPath)) { exit 0 }
    if (-not (Test-Path -LiteralPath $JobPath -PathType Leaf)) { exit 0 }
    $job = Read-CphJsonFile -Path $JobPath
    if ($null -eq $job) {
        try { Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue } catch { }
        exit 0
    }
    $configPath = Get-CphStringField -Object $job -Names @('configPath')
    $title = Get-CphStringField -Object $job -Names @('title')
    $body = Get-CphStringField -Object $job -Names @('body')
    $pendingFile = Get-CphStringField -Object $job -Names @('pendingFile')
    $rawQueue = Get-CphRawField -Object $job -Name 'queue'
    $rawContent = Get-CphRawField -Object $job -Name 'content'
    if ([string]::IsNullOrEmpty($configPath) -or [string]::IsNullOrEmpty($pendingFile)) {
        try { Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue } catch { }
        exit 0
    }
    $content = ConvertTo-WorkerHashtable -Node $rawContent
    $entries = @()
    $queueList = @(ConvertTo-CphArray -Value $rawQueue)
    foreach ($q in $queueList) {
            $qn = ''
            $qd = 15
            try {
                if ($q -is [System.Collections.IDictionary]) {
                    $qn = [string]$q['Channel']
                    $qd = [int]$q['Delay']
                } else {
                    $qn = [string]$q.Channel
                    $qd = [int]$q.Delay
                }
            } catch { continue }
            if ($qn -ne '') { $entries += @{ Channel = $qn; Delay = $qd } }
        }
    $entries = @($entries | Sort-Object -Property Delay)
    $elapsed = 0
    foreach ($e in $entries) {
        $wait = [int]$e['Delay'] - $elapsed
        if ($wait -gt 0) {
            Start-Sleep -Seconds $wait
            if (-not (Test-Path -LiteralPath $pendingFile)) { break }
            $elapsed = [int]$e['Delay']
        }
        try {
            $chCfg = Get-CphChannelConfig -ConfigPath $configPath -Channel $e['Channel']
            if ($null -ne $chCfg) {
                [void](Invoke-CphChannelSend -Channel $e['Channel'] -Title $title -Body $body -ChannelConfig $chCfg -Content $content)
            }
        } catch { }
    }
    try {
        if (Test-Path -LiteralPath $pendingFile) { Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        if (Test-Path -LiteralPath $JobPath) { Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue }
    } catch { }
} catch { }
exit 0
