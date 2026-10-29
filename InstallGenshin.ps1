$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataRoot = Join-Path $env:APPDATA 'InstallGenshin'
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$settingsPath = Join-Path $dataRoot 'settings.json'
$historyPath = Join-Path $dataRoot 'history.json'
$officialUrl = 'https://genshin.hoyoverse.com/en-us/download'
$port = 38127
$baseUrl = "http://127.0.0.1:$port/"

function Read-JsonFile($path, $fallback) {
    if (-not (Test-Path $path)) { return $fallback }
    try { return (Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json) }
    catch { return $fallback }
}
function Save-JsonFile($path, $value) {
    $value | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $path
}
function Write-Response($client, [int]$code, [string]$body, [string]$type) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $reason = if ($code -eq 200) { 'OK' } elseif ($code -eq 400) { 'Bad Request' } elseif ($code -eq 403) { 'Forbidden' } elseif ($code -eq 404) { 'Not Found' } else { 'Internal Server Error' }
    $header = "HTTP/1.1 $code $reason`r`nContent-Type: $type; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`nX-Content-Type-Options: nosniff`r`n`r`n"
    $stream = $client.GetStream()
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}
function Reply-Json($client, [int]$code, $value) {
    Write-Response $client $code ($value | ConvertTo-Json -Depth 8 -Compress) 'application/json'
}
function Read-Request($client) {
    $client.ReceiveTimeout = 5000
    $stream = $client.GetStream()
    $header = [IO.MemoryStream]::new()
    $tail = 0
    while ($header.Length -lt 16384) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { throw '连接已关闭' }
        $header.WriteByte([byte]$b)
        $tail = (($tail -shl 8) -bor $b) -band 0xffffffffL
        if ($tail -eq 0x0d0a0d0a) { break }
    }
    if ($tail -ne 0x0d0a0d0a) { throw '请求头过长' }
    $headerText = [Text.Encoding]::ASCII.GetString($header.ToArray())
    $lines = $headerText -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { throw '无效请求' }
    $headers = @{}
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $index = $line.IndexOf(':')
        if ($index -gt 0) { $headers[$line.Substring(0, $index).ToLowerInvariant()] = $line.Substring($index + 1).Trim() }
    }
    $length = 0
    if ($headers.ContainsKey('content-length')) { $length = [int]$headers['content-length'] }
    if ($length -lt 0 -or $length -gt 65536) { throw '请求内容过长' }
    $bodyBytes = [byte[]]::new($length)
    $read = 0
    while ($read -lt $length) {
        $count = $stream.Read($bodyBytes, $read, $length - $read)
        if ($count -le 0) { throw '请求内容不完整' }
        $read += $count
    }
    return [pscustomobject]@{ method = $parts[0]; path = $parts[1]; headers = $headers; body = [Text.Encoding]::UTF8.GetString($bodyBytes) }
}
function Safe-Url($candidate) {
    $uri = $null
    if ([Uri]::TryCreate([string]$candidate, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') { return $uri.AbsoluteUri }
    return $null
}
function Get-ProcessNames {
    return @(Get-Process | Where-Object { $_.ProcessName } | ForEach-Object { "$($_.ProcessName).exe" } | Sort-Object -Unique)
}
function Record-Event($kind, $detail) {
    $entry = [pscustomobject]@{ time = (Get-Date).ToString('o'); kind = $kind; detail = $detail }
    $script:history = @($entry) + @($script:history) | Select-Object -First 30
    Save-JsonFile $historyPath $script:history
}
function Trigger-Action($isTest) {
    $url = if ($script:settings.action -eq 'custom') { Safe-Url $script:settings.customUrl } else { $officialUrl }
    if (-not $url) { Record-Event 'error' '网页地址无效，请使用 https:// 地址'; return }
    try {
        Start-Process $url
        if (-not $isTest) { $script:settings.lastTriggered = (Get-Date).ToString('o'); Save-JsonFile $settingsPath $script:settings }
        Record-Event $(if ($isTest) { 'test' } else { 'trigger' }) $url
    } catch { Record-Event 'error' "无法打开网页：$($_.Exception.Message)" }
}

$settings = Read-JsonFile $settingsPath ([pscustomobject]@{
    enabled = $false; processName = 'VALORANT-Win64-Shipping.exe'; action = 'genshin';
    customUrl = ''; cooldownMinutes = 30; lastTriggered = $null
})
$history = @(Read-JsonFile $historyPath @())
$wasRunning = $false
$lastCheck = [DateTime]::MinValue
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), $port)
try { $listener.Start() }
catch {
    Write-Host "无法启动本地服务 $baseUrl。请关闭之前启动的 InstallGenshin。" -ForegroundColor Red
    exit 1
}
Write-Host "InstallGenshin 已启动：$baseUrl" -ForegroundColor Cyan
Start-Process $baseUrl
$pending = $listener.BeginAcceptTcpClient($null, $null)
try {
    while ($true) {
        if ((Get-Date) - $lastCheck -ge [TimeSpan]::FromSeconds(2)) {
            $lastCheck = Get-Date
            if ($settings.enabled -and $settings.processName) {
                $target = ([string]$settings.processName).Trim() -replace '\.exe$', ''
                $running = [bool](Get-Process -Name $target -ErrorAction SilentlyContinue)
                if ($running -and -not $wasRunning) {
                    $last = [DateTime]::MinValue
                    if ($settings.lastTriggered) { [DateTime]::TryParse([string]$settings.lastTriggered, [ref]$last) | Out-Null }
                    if ((Get-Date) - $last -ge [TimeSpan]::FromMinutes([int]$settings.cooldownMinutes)) { Trigger-Action $false }
                }
                $wasRunning = $running
            } else { $wasRunning = $false }
        }
        if (-not $pending.IsCompleted) { Start-Sleep -Milliseconds 150; continue }
        try { $client = $listener.EndAcceptTcpClient($pending) }
        catch { break }
        $pending = $listener.BeginAcceptTcpClient($null, $null)
        try {
            $request = Read-Request $client
            $path = $request.path
            $method = $request.method
            if ($request.headers['host'] -ne "127.0.0.1:$port") { Reply-Json $client 403 @{ error = '请求来源不允许' }; continue }
            if ($method -eq 'POST' -and $request.headers['origin'] -ne "http://127.0.0.1:$port") { Reply-Json $client 403 @{ error = '请求来源不允许' }; continue }
            if ($method -eq 'GET' -and $path -eq '/') {
                Write-Response $client 200 (Get-Content -Raw -Encoding UTF8 (Join-Path $appRoot 'index.html')) 'text/html'
            } elseif ($method -eq 'GET' -and $path -eq '/style.css') {
                Write-Response $client 200 (Get-Content -Raw -Encoding UTF8 (Join-Path $appRoot 'style.css')) 'text/css'
            } elseif ($method -eq 'GET' -and $path -eq '/app.js') {
                Write-Response $client 200 (Get-Content -Raw -Encoding UTF8 (Join-Path $appRoot 'app.js')) 'text/javascript'
            } elseif ($method -eq 'GET' -and $path -eq '/api/state') {
                Reply-Json $client 200 @{ settings = $settings; history = @($history); running = $wasRunning; officialUrl = $officialUrl }
            } elseif ($method -eq 'GET' -and $path -eq '/api/processes') {
                Reply-Json $client 200 @{ processes = @(Get-ProcessNames) }
            } elseif ($method -eq 'POST' -and $path -eq '/api/settings') {
                $inputData = $request.body | ConvertFrom-Json
                $name = ([string]$inputData.processName).Trim()
                if ($name.Length -lt 1 -or $name.Length -gt 120 -or $name -match '[\\/:*?"<>|\[\]\r\n]') { Reply-Json $client 400 @{ error = '请输入有效的进程文件名' }; continue }
                if ($name -notmatch '\.exe$') { $name += '.exe' }
                $action = if ($inputData.action -eq 'custom') { 'custom' } else { 'genshin' }
                $url = if ($action -eq 'custom') { Safe-Url $inputData.customUrl } else { $null }
                if ($action -eq 'custom' -and -not $url) { Reply-Json $client 400 @{ error = '自定义网页必须是有效的 https:// 地址' }; continue }
                $cooldown = [int]$inputData.cooldownMinutes
                if ($cooldown -lt 0 -or $cooldown -gt 1440) { Reply-Json $client 400 @{ error = '冷却时间需要在 0 到 1440 分钟之间' }; continue }
                $changed = $settings.processName -ne $name
                $settings.processName = $name
                $settings.action = $action
                $settings.customUrl = if ($url) { $url } else { '' }
                $settings.cooldownMinutes = $cooldown
                $settings.enabled = [bool]$inputData.enabled
                if ($changed) { $wasRunning = $false }
                Save-JsonFile $settingsPath $settings
                Record-Event 'settings' '设置已保存'
                Reply-Json $client 200 @{ ok = $true; settings = $settings }
            } elseif ($method -eq 'POST' -and $path -eq '/api/test') {
                Trigger-Action $true
                Reply-Json $client 200 @{ ok = $true }
            } else { Reply-Json $client 404 @{ error = '未找到此页面' } }
        } catch {
            try { Reply-Json $client 500 @{ error = $_.Exception.Message } } catch { }
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }
