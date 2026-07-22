[CmdletBinding()]
param(
    [switch]$DebugBuild,
    [switch]$Fast,
    [switch]$AllowDirty,
    [string]$Release = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
$Godot = Join-Path $WorkspaceRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'
$BuildDir = Join-Path $ProjectRoot 'builds\pwa'
$EvidenceDir = Join-Path $ProjectRoot 'builds\release-evidence\local'
$TemplateDir = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable'
$TemplateName = if ($DebugBuild) { 'web_nothreads_debug.zip' } else { 'web_nothreads_release.zip' }

function Resolve-Application([string[]]$Names) {
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}

function Resolve-GitExecutable {
    $resolved = Resolve-Application @('git.exe', 'git')
    if ($null -ne $resolved) { return $resolved }
    $candidates = @()
    if ($env:CODEX_GIT_EXECUTABLE) { $candidates += $env:CODEX_GIT_EXECUTABLE }
    $candidates += Join-Path $WorkspaceRoot '.tools\git\cmd\git.exe'
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Git\cmd\git.exe' }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    if ($env:USERPROFILE) {
        $runtimeRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
            return Get-ChildItem -LiteralPath $runtimeRoot -Filter git.exe -File -Recurse `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like '*\dependencies\native\git\cmd\git.exe' } |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
    return $null
}

function Resolve-PythonExecutable {
    $resolved = Resolve-Application @('python.exe', 'python', 'py.exe', 'py')
    if ($null -ne $resolved) { return $resolved }
    if ($env:USERPROFILE) {
        $runtimeRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
            return Get-ChildItem -LiteralPath $runtimeRoot -Filter python.exe -File -Recurse `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like '*\dependencies\python\python.exe' } |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot 4.7 non trovato: $Godot"
}
if (-not (Test-Path -LiteralPath (Join-Path $TemplateDir $TemplateName) -PathType Leaf)) {
    throw "Template Web Godot mancante: $TemplateName"
}
$Python = Resolve-PythonExecutable
if ($null -eq $Python) {
    throw 'Python 3 non trovato: serve per la matrice e la verifica riproducibile della release.'
}
$Git = Resolve-GitExecutable
$publishable = -not $DebugBuild -and -not $AllowDirty
if ($publishable -and $null -eq $Git) {
    throw 'Git non trovato: impossibile dimostrare che la release proviene da un repository pulito.'
}

$resolvedProject = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$resolvedBuild = [IO.Path]::GetFullPath($BuildDir).TrimEnd('\')
if (-not $resolvedBuild.StartsWith($resolvedProject + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Percorso build non sicuro: $resolvedBuild"
}

$commit = ''
if ($null -ne $Git) {
    Push-Location $ProjectRoot
    try {
        $commit = ((& $Git rev-parse HEAD) | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Impossibile leggere il commit Git.' }
        $status = (& $Git status --porcelain --untracked-files=normal) -join "`n"
        if ($publishable -and -not [string]::IsNullOrWhiteSpace($status)) {
            throw 'Release interrotta: il repository contiene modifiche. Fare commit o usare -DebugBuild/-AllowDirty per una build non pubblicabile.'
        }
    } finally {
        Pop-Location
    }
}
if ([string]::IsNullOrWhiteSpace($Release)) {
    $Release = 'local-{0}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
}

New-Item -ItemType Directory -Force -Path $BuildDir, $EvidenceDir | Out-Null
Get-ChildItem -LiteralPath $BuildDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

$toolSmoke = @((Join-Path $ProjectRoot 'tools\release\release_tools_smoke.py'))
if ($null -ne $Git) { $toolSmoke += @('--git', $Git) }
& $Python @toolSmoke
if ($LASTEXITCODE -ne 0) { throw "Smoke test strumenti release fallito con codice $LASTEXITCODE" }

$groups = if ($Fast) { 'release' } else { 'all' }
$matrix = @(
    (Join-Path $ProjectRoot 'tools\release\run_godot_matrix.py'),
    '--godot', $Godot, '--project', $ProjectRoot,
    '--groups', $groups, '--logs', $EvidenceDir
)
if ($publishable) { $matrix += @('--isolate-test-results', '--git', $Git) }
& $Python @matrix
if ($LASTEXITCODE -ne 0) { throw "Matrice Godot fallita con codice $LASTEXITCODE" }

$exportMode = if ($DebugBuild) { '--export-debug' } else { '--export-release' }
& $Godot --headless --path $ProjectRoot $exportMode 'PWA' (Join-Path $BuildDir 'index.html')
if ($LASTEXITCODE -ne 0) { throw "Export PWA fallito con codice $LASTEXITCODE" }

$godotVersion = (& $Godot --version).Trim()
$prepare = @(
    (Join-Path $ProjectRoot 'tools\release\prepare_pwa_artifact.py'),
    '--project', $ProjectRoot,
    '--build', $BuildDir,
    '--commit', $commit,
    '--godot-version', $godotVersion,
    '--release', $Release,
    '--mode', $(if ($DebugBuild) { 'debug' } else { 'release' })
)
if ($null -ne $Git) { $prepare += @('--git', $Git) }
if ($publishable) { $prepare += '--require-clean' }
& $Python @prepare
if ($LASTEXITCODE -ne 0) { throw "Preparazione artifact fallita con codice $LASTEXITCODE" }

$verify = @(
    (Join-Path $ProjectRoot 'tools\release\verify_pwa_artifact.py'),
    '--build', $BuildDir,
    '--evidence', (Join-Path $EvidenceDir 'artifact-verification.json'),
    '--max-total-mib', '65', '--max-wasm-mib', '42', '--max-pck-mib', '25'
)
if ($publishable) { $verify += '--require-publishable' }
& $Python @verify
if ($LASTEXITCODE -ne 0) { throw "Artifact PWA non pubblicabile (codice $LASTEXITCODE)" }

$size = (Get-ChildItem -LiteralPath $BuildDir -File -Recurse | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host "PWA verificata: $BuildDir" -ForegroundColor Green
Write-Host ('Dimensione: {0:N2} MiB (limite 65)' -f ($size / 1MB))
Write-Host "Release: $Release | Commit: $commit | Pubblicabile: $publishable"
Write-Host "Evidence: $EvidenceDir"
