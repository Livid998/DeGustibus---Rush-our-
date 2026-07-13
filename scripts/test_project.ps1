$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$godotCandidates = @(
    $env:GODOT4,
    'C:\Users\Livis\.codex\tools\godot-4.7\Godot_v4.7-stable_win64_console.exe',
    'C:\Users\Livis\.codex\tools\godot-4.7\Godot_v4.7-stable_win64.exe',
    (Get-Command godot4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Get-Command godot -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $godotCandidates) {
    throw 'Godot 4 non trovato. Impostare la variabile GODOT4 con il percorso dell’eseguibile.'
}

$godot = @($godotCandidates)[0]
$result = Join-Path $projectRoot '.smoke-test-result'
Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
$parseArgs = "--headless --editor --path `"$projectRoot`" --quit"
$parse = Start-Process -FilePath $godot -ArgumentList $parseArgs -WindowStyle Hidden -Wait -PassThru
if ($parse.ExitCode -ne 0) { throw "Import/parse Godot fallito con codice $($parse.ExitCode)" }
$env:DEGUSTIBUS_SMOKE = '1'
$smokeArgs = "--headless --path `"$projectRoot`" -- --smoke-test"
$smoke = Start-Process -FilePath $godot -ArgumentList $smokeArgs -WindowStyle Hidden -Wait -PassThru
Remove-Item Env:\DEGUSTIBUS_SMOKE -ErrorAction SilentlyContinue
if ($smoke.ExitCode -ne 0) { throw "Smoke test fallito con codice $($smoke.ExitCode)" }
if (-not (Test-Path $result)) { throw 'Smoke test non completato: report mancante.' }
$text = Get-Content -LiteralPath $result -Raw
Remove-Item -LiteralPath $result
Write-Host $text
