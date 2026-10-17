param(
    [string]$PortName = 'COM7',
    [int]$BaudRate = 1500000,
    [int]$DurationSeconds = 0,
    [switch]$NoKeyboard
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $projectDir 'logs'
[System.IO.Directory]::CreateDirectory($logDir) | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$basePath = Join-Path $logDir ("serial-{0}-{1}" -f $PortName, $stamp)
$rawPath = $basePath + '.bin'
$textPath = $basePath + '.log'
$statusPath = Join-Path $logDir 'serial-capture-status.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$decoder = $utf8.GetDecoder()
$port = New-Object System.IO.Ports.SerialPort $PortName,$BaudRate,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$port.Handshake = [System.IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.ReadTimeout = 200
$port.WriteTimeout = 1000
$port.ReadBufferSize = 65536
$raw = $null
$text = $null
$oldControlC = $null
$totalBytes = 0L
$startedAt = [DateTime]::Now.ToString('o')
$errorText = $null

function Save-Status([string]$State) {
    $info = [ordered]@{
        state = $State
        pid = $PID
        port = $PortName
        baud = $BaudRate
        format = '8N1; no flow control'
        startedAt = $startedAt
        updatedAt = [DateTime]::Now.ToString('o')
        receivedBytes = $totalBytes
        rawLog = $rawPath
        textLog = $textPath
        error = $errorText
    }
    [System.IO.File]::WriteAllText($statusPath, ($info | ConvertTo-Json), $utf8)
}

try {
    $port.Open()
    $raw = [System.IO.File]::Open($rawPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stream = [System.IO.File]::Open($textPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $text = New-Object System.IO.StreamWriter($stream, $utf8)
    $text.AutoFlush = $true
    if (-not $NoKeyboard) {
        $oldControlC = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $true
    }
    Write-Host ("Listening on {0}: {1}, 8N1, no flow control." -f $PortName, $BaudRate)
    Write-Host 'Power-cycle the board to capture boot output. Do not hold REC or MASKROM.'
    Write-Host 'Typed characters go to the board. Press Ctrl+] to stop and release the port.'
    Write-Host ("Log: {0}" -f $textPath)
    Save-Status 'listening'
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 0.0
    $buffer = New-Object byte[] 8192
    $chars = New-Object char[] 16384
    while ($DurationSeconds -le 0 -or $timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if ($port.BytesToRead -gt 0) {
            $count = $port.Read($buffer, 0, [Math]::Min($buffer.Length, $port.BytesToRead))
            if ($count -gt 0) {
                $raw.Write($buffer, 0, $count)
                $raw.Flush()
                $totalBytes += $count
                $charCount = $decoder.GetChars($buffer, 0, $count, $chars, 0, $false)
                if ($charCount -gt 0) {
                    $output = [string]::new($chars, 0, $charCount)
                    [Console]::Write($output)
                    $text.Write($output)
                }
            }
        }
        if (-not $NoKeyboard -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ([int]$key.KeyChar -eq 29) { break }
            if ([int]$key.KeyChar -ne 0) { $port.Write([string]$key.KeyChar) }
        }
        if ($timer.Elapsed.TotalSeconds - $lastStatus -ge 1) {
            Save-Status 'listening'
            $lastStatus = $timer.Elapsed.TotalSeconds
        }
        Start-Sleep -Milliseconds 20
    }
} catch {
    $errorText = $_.Exception.Message
    Write-Host ("Capture error: {0}" -f $errorText) -ForegroundColor Red
} finally {
    if ($port.IsOpen) { $port.Close() }
    $port.Dispose()
    if ($null -ne $text) { $text.Dispose() }
    if ($null -ne $raw) { $raw.Dispose() }
    if ($null -ne $oldControlC) { [Console]::TreatControlCAsInput = $oldControlC }
    if ($null -ne $errorText) { Save-Status 'error' } else { Save-Status 'stopped' }
}
if ($null -ne $errorText) { exit 1 }
