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

$icon192Source = Join-Path $ProjectRoot 'web\pwa_icon_192.png'
if (-not (Test-Path -LiteralPath $icon192Source -PathType Leaf)) {
    throw "Icona PWA 192x192 mancante: $icon192Source"
}
Copy-Item -LiteralPath $icon192Source `
    -Destination (Join-Path $BuildDir 'index.192x192.png') -Force

$manifestPath = Join-Path $BuildDir 'index.manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$manifest.orientation = 'any'
$manifest | Add-Member -NotePropertyName id -NotePropertyValue './' -Force
$manifest | Add-Member -NotePropertyName scope -NotePropertyValue './' -Force
$icons = @(
    $manifest.icons |
        Where-Object { $_.sizes -ne '192x192' } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                sizes = $_.sizes
                src = $_.src
                type = $_.type
                purpose = 'any'
            }
        }
)
$icons += [pscustomobject][ordered]@{
    sizes = '192x192'
    src = 'index.192x192.png'
    type = 'image/png'
    purpose = 'any'
}
$manifest.icons = @($icons | Sort-Object { [int]($_.sizes.Split('x')[0]) })
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 8 -Compress),
    [Text.UTF8Encoding]::new($false)
)

function Resolve-GitExecutable {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_GIT_EXECUTABLE)) {
        $candidates += $env:CODEX_GIT_EXECUTABLE
    }
    $candidates += Join-Path $WorkspaceRoot '.tools\git\cmd\git.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'
    }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $runtimeRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
            $bundled = Get-ChildItem -LiteralPath $runtimeRoot -Filter git.exe `
                -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -like '*\dependencies\native\git\cmd\git.exe'
                } |
                Select-Object -First 1 -ExpandProperty FullName
            if (-not [string]::IsNullOrWhiteSpace($bundled)) {
                return $bundled
            }
        }
    }
    return $null
}

function Read-HeadCommit {
    $gitMarker = Join-Path $ProjectRoot '.git'
    $gitDirectory = $gitMarker
    if (Test-Path -LiteralPath $gitMarker -PathType Leaf) {
        $marker = (Get-Content -Raw -LiteralPath $gitMarker).Trim()
        if ($marker.StartsWith('gitdir: ')) {
            $gitDirectory = [IO.Path]::GetFullPath(
                (Join-Path $ProjectRoot $marker.Substring(8).Trim())
            )
        }
    }
    $headPath = Join-Path $gitDirectory 'HEAD'
    if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) {
        return $null
    }
    $head = (Get-Content -Raw -LiteralPath $headPath).Trim()
    if (-not $head.StartsWith('ref: ')) {
        return $head
    }
    $refName = $head.Substring(5).Trim()
    $refPath = Join-Path $gitDirectory $refName.Replace('/', '\')
    if (Test-Path -LiteralPath $refPath -PathType Leaf) {
        return (Get-Content -Raw -LiteralPath $refPath).Trim()
    }
    $packedRefsPath = Join-Path $gitDirectory 'packed-refs'
    if (Test-Path -LiteralPath $packedRefsPath -PathType Leaf) {
        $packed = Get-Content -LiteralPath $packedRefsPath |
            Where-Object { $_ -match "^[0-9a-fA-F]{40}\s+$([regex]::Escape($refName))$" } |
            Select-Object -First 1
        if ($null -ne $packed) {
            return $packed.Split(' ')[0]
        }
    }
    return $null
}

$gitPath = Resolve-GitExecutable
$commit = $null
$dirty = $null
$sourceState = 'unknown'
if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
    Push-Location $ProjectRoot
    try {
        $commitOutput = (& $gitPath rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $commit = ($commitOutput | Select-Object -First 1).Trim()
        }
        $statusOutput = (& $gitPath status --porcelain --untracked-files=normal 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $dirty = -not [string]::IsNullOrWhiteSpace(($statusOutput -join "`n"))
            $sourceState = if ($dirty) { 'dirty' } else { 'clean' }
        }
    } finally {
        Pop-Location
    }
}
if ([string]::IsNullOrWhiteSpace($commit)) {
    $commit = Read-HeadCommit
}

$buildInfo = [ordered]@{
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    godot = (& $Godot --version).Trim()
    mode = if ($DebugBuild) { 'debug' } else { 'release' }
    commit = $commit
    dirty = $dirty
    source_state = $sourceState
    offline_cache = 'runtime-cache-after-first-controlled-load'
}
$buildInfoPath = Join-Path $BuildDir 'build-info.json'
[IO.File]::WriteAllText(
    $buildInfoPath,
    ($buildInfo | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

$serviceWorkerPath = Join-Path $BuildDir 'index.service.worker.js'
$serviceWorker = [IO.File]::ReadAllText($serviceWorkerPath)
if (-not $serviceWorker.Contains('cache.addAll(CACHED_FILES)') -or
    -not $serviceWorker.Contains('const CACHEABLE_FILES = ["index.wasm","index.pck"]')) {
    throw 'Service worker Godot non riconosciuto: impossibile verificare la cache offline.'
}
$cachedMatch = [regex]::Match(
    $serviceWorker,
    'const CACHED_FILES = (?<files>\[[^\r\n]*\]);'
)
if (-not $cachedMatch.Success) {
    throw 'Elenco precache del service worker non trovato.'
}
$parsedCachedFiles = ConvertFrom-Json -InputObject $cachedMatch.Groups['files'].Value
$cachedFiles = @()
foreach ($cachedFile in $parsedCachedFiles) {
    $cachedFiles += [string]$cachedFile
}
foreach ($asset in @(
    'index.manifest.json',
    'index.144x144.png',
    'index.180x180.png',
    'index.192x192.png',
    'index.512x512.png',
    'build-info.json'
)) {
    if ($asset -notin $cachedFiles) {
        $cachedFiles += $asset
    }
}
$cachedDeclaration = 'const CACHED_FILES = {0};' -f (
    ConvertTo-Json -InputObject $cachedFiles -Compress
)
$serviceWorker = $serviceWorker.Remove(
    $cachedMatch.Index,
    $cachedMatch.Length
).Insert($cachedMatch.Index, $cachedDeclaration)
$firstInstallClaimMarker = '// DeGustibus first-install control'
if (-not $serviceWorker.Contains($firstInstallClaimMarker)) {
    $serviceWorker += @'

// DeGustibus first-install control: claim the already-open page only when
// there is no previous active worker. Later updates keep waiting for the
// explicit "Aggiorna e riavvia" action.
self.addEventListener('install', (event) => {
	if (!self.registration.active) {
		event.waitUntil(self.skipWaiting());
	}
});
self.addEventListener('activate', (event) => {
	event.waitUntil(self.clients.claim());
});
'@
}
[IO.File]::WriteAllText(
    $serviceWorkerPath,
    $serviceWorker,
    [Text.UTF8Encoding]::new($false)
)

[IO.File]::WriteAllText(
    (Join-Path $BuildDir '.nojekyll'),
    '',
    [Text.UTF8Encoding]::new($false)
)

$finalManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$finalSizes = @($finalManifest.icons | ForEach-Object { $_.sizes })
if ($finalManifest.orientation -ne 'any' -or
    '192x192' -notin $finalSizes -or
    '512x512' -notin $finalSizes) {
    throw 'Manifest PWA finale non valido.'
}
foreach ($required in @(
    'index.html',
    'index.js',
    'index.wasm',
    'index.pck',
    'index.service.worker.js',
    'index.manifest.json',
    'index.192x192.png',
    'index.512x512.png',
    'build-info.json'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $required) -PathType Leaf)) {
        throw "File PWA finale mancante: $required"
    }
}

$size = (Get-ChildItem -LiteralPath $BuildDir -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host "PWA pronta: $BuildDir" -ForegroundColor Green
Write-Host ('Dimensione: {0:N1} MB' -f ($size / 1MB))
Write-Host "Commit: $commit ($sourceState)"
Write-Host 'Il secondo avvio completa la cache runtime; da quello successivo la PWA funziona offline.'
