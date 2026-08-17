<#
.SYNOPSIS
    Downloads a portable (no-install) ImageMagick build - including libheif
    (HEIC read) and libaom (AVIF read/write) - into this folder, so the photo
    scripts have their dependency without touching the system installation.

.DESCRIPTION
    ImageMagick's official Windows "portable" builds are distributed as .7z
    archives on GitHub Releases. This script:
      1. Resolves the release (latest, or a fixed -Version like '7.1.2-29').
      2. Downloads the portable .7z for this machine's architecture.
      3. Extracts it with the Windows-bundled tar.exe (bsdtar/libarchive, which
         reads 7-Zip) - no 7-Zip install required.
      4. Verifies magick.exe runs and reports the heic + avif delegates.
      5. Leaves everything under <ScriptFolder>\tools\ImageMagick so that
         Compress-PhotoLibrary.ps1 auto-detects it (no -MagickPath needed).

    Nothing is installed, no PATH or registry changes are made. Delete the
    'tools' folder to remove it completely.

.PARAMETER Version
    'latest' (default) resolves the newest GitHub release. Otherwise pass a
    fixed release tag such as '7.1.2-29' for reproducible builds.

.PARAMETER Quantum
    Quantum/depth variant. Default 'Q16-HDRI' (matches a normal desktop build).
    Other portable variants published upstream include 'Q16' and 'Q8'.

.PARAMETER DestinationRoot
    Where to place the 'ImageMagick' folder. Default: <ScriptFolder>\tools.

.PARAMETER ExpectedSha256
    Optional. If given, the download must match this SHA-256 or the script aborts.
    (The script always prints the computed hash so you can pin it next time.)

.PARAMETER Force
    Re-download and re-extract even if a working copy already exists.

.EXAMPLE
    .\Get-PortableImageMagick.ps1
    # newest release, auto architecture, into .\tools\ImageMagick

.EXAMPLE
    .\Get-PortableImageMagick.ps1 -Version 7.1.2-29
    # pin a fixed, reproducible version
#>

[CmdletBinding()]
param(
    [string] $Version = 'latest',
    [ValidateSet('Q16-HDRI','Q16','Q8')]
    [string] $Quantum = 'Q16-HDRI',
    [string] $DestinationRoot,
    [string] $ExpectedSha256,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DestinationRoot) { $DestinationRoot = Join-Path $ScriptDir 'tools' }
$InstallDir = Join-Path $DestinationRoot 'ImageMagick'

# --- Architecture -> asset suffix -----------------------------------------
$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
switch ($osArch) {
    'X64'   { $arch = 'x64' }
    'Arm64' { $arch = 'arm64' }
    'X86'   { $arch = 'x86' }
    default { throw "Unsupported OS architecture: $osArch" }
}
# Upstream does not publish an HDRI x86 in all releases; Q8 has no HDRI variant.
$variant = if ($Quantum -eq 'Q8') { "Q8-$arch" } else { "$Quantum-$arch" }

# --- tar.exe (bsdtar) is required to extract .7z ---------------------------
$tar = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
if (-not $tar) {
    throw "tar.exe (bsdtar) not found. It ships with Windows 10/11. On older Windows, install 7-Zip and extract the .7z manually."
}

function Invoke-GitHubJson {
    param([string] $Url)
    $headers = @{ 'User-Agent' = 'PhotoLibraryMinimise'; 'Accept' = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri $Url -Headers $headers -MaximumRedirection 5
}

# --- Resolve release tag + asset URL --------------------------------------
Write-Host "Resolving ImageMagick release ($Version, $variant)..." -ForegroundColor Cyan
$repo = 'ImageMagick/ImageMagick'
$assetName = $null
$assetUrl  = $null
$tag       = $null

try {
    if ($Version -eq 'latest') {
        $rel = Invoke-GitHubJson "https://api.github.com/repos/$repo/releases/latest"
    } else {
        $rel = Invoke-GitHubJson "https://api.github.com/repos/$repo/releases/tags/$Version"
    }
    $tag = $rel.tag_name
    $wantName = "ImageMagick-$tag-portable-$variant.7z"
    $asset = $rel.assets | Where-Object { $_.name -eq $wantName } | Select-Object -First 1
    if (-not $asset) {
        $portable = ($rel.assets | Where-Object { $_.name -like '*portable*.7z' } | ForEach-Object name) -join "`n  "
        throw "Release $tag has no asset '$wantName'. Available portable assets:`n  $portable"
    }
    $assetName = $asset.name
    $assetUrl  = $asset.browser_download_url
}
catch {
    # Fallback: construct the conventional URL directly (e.g. GitHub API rate-limited).
    if ($Version -eq 'latest') { throw "Could not query GitHub API for the latest release: $($_.Exception.Message)" }
    $tag = $Version
    $assetName = "ImageMagick-$tag-portable-$variant.7z"
    $assetUrl  = "https://github.com/$repo/releases/download/$tag/$assetName"
    Write-Warning "GitHub API lookup failed; falling back to direct URL for $assetName."
}

Write-Host "  Release : $tag" -ForegroundColor DarkGray
Write-Host "  Asset   : $assetName" -ForegroundColor DarkGray

# --- Already installed? ----------------------------------------------------
$existing = Join-Path $InstallDir 'magick.exe'
$verFile  = Join-Path $InstallDir '.version'
if ((Test-Path -LiteralPath $existing) -and -not $Force) {
    $have = if (Test-Path -LiteralPath $verFile) { (Get-Content -LiteralPath $verFile -Raw).Trim() } else { '(unknown)' }
    if ($have -eq $tag) {
        Write-Host "ImageMagick $tag already present at $InstallDir. Use -Force to reinstall." -ForegroundColor Green
        Write-Host "magick.exe: $existing"
        return
    }
    Write-Host "A different version ($have) is present; replacing with $tag." -ForegroundColor Yellow
}

# --- Download --------------------------------------------------------------
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$dl = Join-Path $DestinationRoot $assetName
$part = "$dl.part"
if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }

Write-Host "Downloading $assetUrl" -ForegroundColor Cyan
$oldPref = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'   # IWR's progress bar cripples large-file speed
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $assetUrl -OutFile $part -MaximumRedirection 5 -Headers @{ 'User-Agent' = 'PhotoLibraryMinimise' }
    $sw.Stop()
}
finally { $ProgressPreference = $oldPref }

$size = (Get-Item -LiteralPath $part).Length
Write-Host ("  Downloaded {0:N1} MB in {1:N0}s" -f ($size / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

# --- Checksum --------------------------------------------------------------
$hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "  SHA-256 : $hash" -ForegroundColor DarkGray
if ($ExpectedSha256) {
    if ($hash -ne $ExpectedSha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $part -Force
        throw "SHA-256 mismatch. Expected $ExpectedSha256 but got $hash. Download discarded."
    }
    Write-Host "  Checksum verified." -ForegroundColor Green
}

Move-Item -LiteralPath $part -Destination $dl -Force

# --- Extract ---------------------------------------------------------------
Write-Host "Extracting with $tar ..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
$extractTmp = Join-Path $DestinationRoot ('_extract_' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null
try {
    & $tar -x -f "$dl" -C "$extractTmp"
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)." }

    # Portable archives may extract flat or inside a top-level folder. Locate magick.exe.
    $magick = Get-ChildItem -LiteralPath $extractTmp -Recurse -Filter 'magick.exe' -File | Select-Object -First 1
    if (-not $magick) { throw "magick.exe not found in the extracted archive." }
    $srcDir = $magick.Directory.FullName

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    # Move the contents of the folder that contains magick.exe into $InstallDir.
    Get-ChildItem -LiteralPath $srcDir -Force | Move-Item -Destination $InstallDir -Force
}
finally {
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
}
$tag | Set-Content -LiteralPath $verFile -NoNewline
Remove-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue   # keep the folder tidy

$magickExe = Join-Path $InstallDir 'magick.exe'
if (-not (Test-Path -LiteralPath $magickExe)) { throw "Extraction succeeded but $magickExe is missing." }

# --- Verify ----------------------------------------------------------------
Write-Host "`nVerifying..." -ForegroundColor Cyan
$verLine = (& $magickExe -version | Select-Object -First 1)
Write-Host "  $verLine"
$formats = & $magickExe -list format
$heic = ($formats | Select-String -Pattern '^\s*HEIC' ) -ne $null
$avifLine = ($formats | Select-String -Pattern '^\s*AVIF')
$avifWrite = $avifLine -and ($avifLine.ToString() -match 'rw')
Write-Host ("  HEIC (read)  : {0}" -f $(if ($heic) {'yes'} else {'NO'})) -ForegroundColor $(if ($heic){'Green'}else{'Red'})
Write-Host ("  AVIF (write) : {0}" -f $(if ($avifWrite) {'yes'} else {'NO'})) -ForegroundColor $(if ($avifWrite){'Green'}else{'Yellow'})

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Portable ImageMagick $tag is at:" -ForegroundColor Green
Write-Host "  $magickExe"
Write-Host "Compress-PhotoLibrary.ps1 auto-detects this location - no -MagickPath needed." -ForegroundColor Green
