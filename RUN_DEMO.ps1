$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Get-Command godot -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Get-Command godot4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path (Split-Path -Parent $project) '.tools\godot-4.7\Godot_v4.7-stable_win64.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if (-not $candidates) {
    throw 'Godot 4.7+ non trovato. Installa Godot oppure aggiungilo al PATH.'
}

Start-Process -FilePath $candidates[0] -WorkingDirectory $project -ArgumentList @('--path', $project)
