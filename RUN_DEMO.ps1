$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    $env:GODOT4,
    'C:\Users\Livis\.codex\tools\godot-4.7\Godot_v4.7-stable_win64.exe',
    (Get-Command godot4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Get-Command godot -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) {
    throw 'Godot 4.7 non trovato. Installarlo da godotengine.org o impostare GODOT4.'
}

$godot = @($candidates)[0]
Start-Process -FilePath $godot -ArgumentList "--path `"$root`"" -WorkingDirectory $root

