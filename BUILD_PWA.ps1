[CmdletBinding()]
param(
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
$Godot = Join-Path $WorkspaceRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'
$BuildDir = Join-Path $ProjectRoot 'builds\pwa'
$TemplateDir = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable'
$TemplateName = if ($DebugBuild) { 'web_nothreads_debug.zip' } else { 'web_nothreads_release.zip' }

if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot 4.7 non trovato: $Godot"
}
if (-not (Test-Path -LiteralPath (Join-Path $TemplateDir $TemplateName))) {
    throw "Template Web Godot mancante: $TemplateName"
}

$resolvedProject = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$resolvedBuild = [IO.Path]::GetFullPath($BuildDir).TrimEnd('\')
if (-not $resolvedBuild.StartsWith($resolvedProject + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Percorso build non sicuro: $resolvedBuild"
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
Get-ChildItem -LiteralPath $BuildDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

& $Godot --headless --path $ProjectRoot --scene 'res://tests/ui_glyph_audit.tscn'
if ($LASTEXITCODE -ne 0) {
    throw "Audit glifi UI/Web fallito con codice $LASTEXITCODE"
}

& $Godot --headless --path $ProjectRoot --scene 'res://tests/responsive_ui_smoke.tscn'
if ($LASTEXITCODE -ne 0) {
    throw "Smoke test UI responsive fallito con codice $LASTEXITCODE"
}

& $Godot --headless --path $ProjectRoot --scene 'res://tests/pwa_delivery_smoke.tscn'
if ($LASTEXITCODE -ne 0) {
    throw "Verifica configurazione PWA fallita con codice $LASTEXITCODE"
}

$exportMode = if ($DebugBuild) { '--export-debug' } else { '--export-release' }
& $Godot --headless --path $ProjectRoot $exportMode 'PWA' (Join-Path $BuildDir 'index.html')
if ($LASTEXITCODE -ne 0) {
    throw "Export PWA fallito con codice $LASTEXITCODE"
}

$buildInfo = [ordered]@{
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    godot = (& $Godot --version).Trim()
    mode = if ($DebugBuild) { 'debug' } else { 'release' }
}
$buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BuildDir 'build-info.json') -Encoding UTF8

$size = (Get-ChildItem -LiteralPath $BuildDir -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host "PWA pronta: $BuildDir" -ForegroundColor Green
Write-Host ('Dimensione: {0:N1} MB' -f ($size / 1MB))
Write-Host 'Ogni nuovo export genera automaticamente una nuova versione del service worker.'
