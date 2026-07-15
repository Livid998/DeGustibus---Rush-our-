[CmdletBinding()]
param(
    [int]$Port = 8060,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$WebRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'builds\pwa'))

if (-not $NoBuild) {
    & (Join-Path $ProjectRoot 'BUILD_PWA.ps1')
}
if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'index.html'))) {
    throw 'Build PWA assente. Esegui prima BUILD_PWA.ps1.'
}

$address = [Net.IPAddress]::Any
$listener = [Net.Sockets.TcpListener]::new($address, $Port)
$listener.Start()

$lanIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object InterfaceMetric |
    Select-Object -First 1 -ExpandProperty IPAddress

Write-Host ''
Write-Host 'Anteprima PWA avviata. Premi Ctrl+C per fermarla.' -ForegroundColor Green
Write-Host "PC:     http://127.0.0.1:$Port"
if ($lanIp) {
    Write-Host "Tablet: http://${lanIp}:$Port"
}
Write-Host 'Su tablet via HTTP il gioco è testabile, ma installazione/offline/aggiornamenti PWA richiedono hosting HTTPS.' -ForegroundColor Yellow

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js' = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.wasm' = 'application/wasm'
    '.pck' = 'application/octet-stream'
    '.png' = 'image/png'
    '.svg' = 'image/svg+xml'
    '.ico' = 'image/x-icon'
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
            }

            $parts = $requestLine.Split(' ')
            $requestPath = if ($parts.Count -ge 2) { [Uri]::UnescapeDataString($parts[1].Split('?')[0]) } else { '/' }
            if ($requestPath -eq '/') { $requestPath = '/index.html' }
            $relative = $requestPath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
            $candidate = [IO.Path]::GetFullPath((Join-Path $WebRoot $relative))

            if (-not $candidate.StartsWith($WebRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $body = [Text.Encoding]::UTF8.GetBytes('404 - File non trovato')
                $header = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($body, 0, $body.Length)
                continue
            }

            $extension = [IO.Path]::GetExtension($candidate).ToLowerInvariant()
            $contentType = if ($mime.ContainsKey($extension)) { $mime[$extension] } else { 'application/octet-stream' }
            $file = [IO.File]::OpenRead($candidate)
            try {
                $cache = if ($extension -in '.html', '.js', '.json') { 'no-cache' } else { 'public, max-age=60' }
                $header = "HTTP/1.1 200 OK`r`nContent-Type: $contentType`r`nContent-Length: $($file.Length)`r`nCache-Control: $cache`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $file.CopyTo($stream)
            } finally {
                $file.Dispose()
            }
        } catch {
            Write-Warning $_.Exception.Message
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
