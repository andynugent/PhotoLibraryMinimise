<#
.SYNOPSIS
    Creates size-reduced copies of a large photo library while retaining all
    metadata, mirroring the folder structure, and stamping each output file's
    creation/modified time with the photo's "date taken".

.DESCRIPTION
    Designed for keeping a full, offline copy of a big photo library on a phone
    without a cloud service. It walks a source tree, produces compressed /
    downscaled versions in a destination tree (same sub-folders + filenames),
    and can be re-run repeatedly to pick up only new or changed photos.

    Change detection uses a manifest (JSON-lines) stored in the destination
    root. Each entry records the source file's LastWriteTimeUtc, size, and the
    settings used. A file is (re)processed when:
      * it is new, or
      * the destination file is missing, or
      * the source LastWriteTimeUtc changed (e.g. you edited GPS/EXIF), or
      * the MaxPixels or Quality settings differ from when it was last made.

    Images larger than -MaxPixels (longest edge) are downscaled preserving
    aspect ratio; smaller images are never upscaled. JPEG quality is set with
    -Quality. All EXIF/XMP/IPTC/ICC metadata is preserved by ImageMagick.

    REQUIREMENTS
      * PowerShell 7+  (for ForEach-Object -Parallel)
      * ImageMagick 7  (magick.exe on PATH, or pass -MagickPath)

.PARAMETER SourceFolder
    Root folder of the original photo library (read-only; never modified).

.PARAMETER DestinationFolder
    Root folder for the reduced copies. Created if missing. The manifest and a
    settings file live here.

.PARAMETER MaxPixels
    Maximum length of the longest edge, in pixels. Larger images are shrunk to
    fit; smaller images are left as-is. Default 2048.

.PARAMETER Quality
    Encoder quality 1-100 (higher = better/larger). Default 85. Applies to JPEG,
    AVIF, HEIC, WebP, etc. Note the scales differ between codecs: AVIF/HEIC at
    ~50-63 typically look equivalent to JPEG ~85 while being much smaller.

.PARAMETER OutputFormat
    Destination image format. 'same' (default) keeps each source's own format and
    extension. Otherwise all outputs are written in the chosen codec and the file
    extension changes accordingly (the base filename is preserved):
      jpg/jpeg  - universal, largest files
      avif      - AV1-based; best compression, royalty-free; read+write here
      heic/heif - HEVC-based; needs an ImageMagick build with an HEVC ENCODER
                  (the stock imagemagick.org Windows build can READ but not WRITE
                  HEIC). The script checks writability up front and tells you.
      webp/png/jxl/tiff - also supported if the build can write them.
    The script verifies the target format is writable before starting.

.PARAMETER AvifSpeed
    Encoder effort for AVIF/HEIC output, passed as '-define heic:speed=N'.
    0 = slowest/smallest, 9 = fastest/largest. Default -1 leaves the encoder's
    own (fast) default in place. Lower values yield noticeably smaller files but
    cost many times more CPU per image - fine for a small favourites folder, but
    impractical for a whole 100k library. Ignored for non-AVIF/HEIC formats.

.PARAMETER FullRefresh
    Ignore the manifest and reprocess every image, overwriting the destination.

.PARAMETER EstimateOnly
    Do not process the whole library. Instead compress a random sample to a temp
    folder, measure the average output size, and report an estimated total size
    for the destination. Nothing in the destination is changed.

.PARAMETER SampleSize
    Number of images to sample for -EstimateOnly (default 60).

.PARAMETER Extensions
    Image file extensions to include (without dot). Default covers common photo
    formats. HEIC/HEIF require ImageMagick built with the HEIC delegate.

.PARAMETER Mirror
    Also delete destination files (and manifest entries) whose source no longer
    exists, so the destination exactly mirrors the source.

.PARAMETER ThrottleLimit
    Parallel worker count. Default = CPU core count.

.PARAMETER ChunkSize
    How many files to process between manifest checkpoints. Default 500.

.PARAMETER MagickPath
    Full path to magick.exe if it is not on PATH. If omitted, the script looks
    for a portable copy at <ScriptFolder>\tools\ImageMagick\magick.exe; if that
    is missing it auto-runs Get-PortableImageMagick.ps1 to download one (see
    -NoDownload), and finally falls back to magick on PATH.

.PARAMETER NoDownload
    Do not auto-download a portable ImageMagick when none is found; use magick on
    PATH instead (or fail with guidance if PATH has none).

.EXAMPLE
    # First, estimate how big the phone copy will be at these settings:
    .\Compress-PhotoLibrary.ps1 -SourceFolder D:\Photos -DestinationFolder E:\PhoneCopy `
        -MaxPixels 2048 -Quality 85 -EstimateOnly

.EXAMPLE
    # Do the real run (re-runnable; only new/changed files are processed):
    .\Compress-PhotoLibrary.ps1 -SourceFolder D:\Photos -DestinationFolder E:\PhoneCopy `
        -MaxPixels 2048 -Quality 85

.EXAMPLE
    # Output everything as AVIF (smaller than JPEG/HEIC; Pixel/Android displays it):
    .\Compress-PhotoLibrary.ps1 -SourceFolder D:\Photos -DestinationFolder E:\PhoneCopy `
        -MaxPixels 2048 -Quality 60 -OutputFormat avif

.EXAMPLE
    # Force a complete rebuild of the destination:
    .\Compress-PhotoLibrary.ps1 -SourceFolder D:\Photos -DestinationFolder E:\PhoneCopy -FullRefresh
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceFolder,
    [Parameter(Mandatory)] [string] $DestinationFolder,
    [ValidateRange(16, 100000)] [int] $MaxPixels = 2048,
    [ValidateRange(1, 100)]     [int] $Quality   = 85,
    [ValidateSet('same','jpg','jpeg','avif','heic','heif','webp','png','jxl','tiff')]
    [string] $OutputFormat = 'same',
    [ValidateRange(-1, 9)] [int] $AvifSpeed = -1,
    [switch] $FullRefresh,
    [switch] $EstimateOnly,
    [ValidateRange(1, 100000)]  [int] $SampleSize = 60,
    [string[]] $Extensions = @('jpg','jpeg','jpe','png','tif','tiff','heic','heif','webp','bmp'),
    [switch] $Mirror,
    [int] $ThrottleLimit = [Environment]::ProcessorCount,
    [ValidateRange(1, 100000)] [int] $ChunkSize = 500,
    [string] $MagickPath,
    [switch] $NoDownload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+ (found $($PSVersionTable.PSVersion))."
}

if (-not $MagickPath) {
    $scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
    $portable   = Join-Path $scriptDir 'tools\ImageMagick\magick.exe'
    $downloader = Join-Path $scriptDir 'Get-PortableImageMagick.ps1'

    # 1) If no portable copy exists yet, auto-download one via the helper script
    #    (unless -NoDownload). This makes the tool self-bootstrapping.
    if (-not (Test-Path -LiteralPath $portable) -and -not $NoDownload -and (Test-Path -LiteralPath $downloader)) {
        Write-Host "Portable ImageMagick not found - fetching it with Get-PortableImageMagick.ps1..." -ForegroundColor Yellow
        try {
            & $downloader -Minimal
        } catch {
            Write-Warning "Automatic ImageMagick download failed: $($_.Exception.Message)"
        }
    }

    # 2) Prefer the portable copy; otherwise fall back to magick on PATH.
    if (Test-Path -LiteralPath $portable) {
        $MagickPath = $portable
    } else {
        $cmd = Get-Command magick -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $hint = if ($NoDownload) { 'Remove -NoDownload to auto-download it, ' } else { 'Run Get-PortableImageMagick.ps1 to download a portable copy, ' }
            throw "ImageMagick 'magick.exe' was not found. $hint" + "install ImageMagick 7, or pass -MagickPath."
        }
        $MagickPath = $cmd.Source
    }
}
if (-not (Test-Path -LiteralPath $MagickPath)) {
    throw "MagickPath not found: $MagickPath"
}
Write-Host "Using ImageMagick: $MagickPath" -ForegroundColor DarkGray

$SourceFolder = (Resolve-Path -LiteralPath $SourceFolder).Path
if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
    throw "SourceFolder is not a folder: $SourceFolder"
}
if (-not (Test-Path -LiteralPath $DestinationFolder)) {
    New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
}
$DestinationFolder = (Resolve-Path -LiteralPath $DestinationFolder).Path

$ManifestPath = Join-Path $DestinationFolder '.photolib-manifest.jsonl'

# Lowercased extension set for fast membership tests.
$extSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $Extensions) { [void]$extSet.Add($e.TrimStart('.')) }

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1PB) { return ('{0:N2} PB' -f ($Bytes / 1PB)) }
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [long]$Bytes)
}

# Cache of {extension -> can magick write it?} so we test each codec only once.
$script:writeCache = @{}
function Test-MagickCanWrite {
    param([string] $Ext, [string] $MagickExe)
    $ext = $Ext.TrimStart('.').ToLowerInvariant()
    if ($script:writeCache.ContainsKey($ext)) { return $script:writeCache[$ext] }
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ("mwtest_" + [System.IO.Path]::GetRandomFileName() + '.' + $ext)
    $ok = $false
    try {
        & $MagickExe -size 8x8 xc:red "$probe" 2>$null | Out-Null
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe).Length -gt 0)
    } catch { $ok = $false }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } }
    $script:writeCache[$ext] = $ok
    return $ok
}

# Resolve the destination path for a source relative path, applying OutputFormat.
# 'same' keeps the source extension; otherwise the extension is swapped.
function Get-DestPath {
    param([string] $DestRoot, [string] $Rel, [string] $OutputFormat)
    if ($OutputFormat -eq 'same') {
        return (Join-Path $DestRoot $Rel)
    }
    $dir  = [System.IO.Path]::GetDirectoryName($Rel)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Rel)
    $newRel = if ($dir) { Join-Path $dir "$name.$OutputFormat" } else { "$name.$OutputFormat" }
    return (Join-Path $DestRoot $newRel)
}

# ---------------------------------------------------------------------------
# Core per-image worker. Defined as a function so it can be reused both in the
# parallel pipeline and for the sampling estimate. Returns a result object.
# ---------------------------------------------------------------------------
function Convert-OneImage {
    param(
        [string] $Source,
        [string] $Dest,
        [int]    $MaxPixels,
        [int]    $Quality,
        [string] $MagickExe,
        [string] $OutExt,      # target extension, e.g. 'jpg' or 'avif' (defaults to $Dest's)
        [int]    $AvifSpeed = -1
    )
    if (-not $OutExt) { $OutExt = [System.IO.Path]::GetExtension($Dest).TrimStart('.') }

    $result = [ordered]@{
        Success   = $false
        DestLength = 0L
        TakenIso  = $null
        Error     = $null
    }

    try {
        # 1. Read the "date taken" from EXIF (source). Try Original, then
        #    Digitized, then the generic DateTime tag. Empty if none present.
        $fmt = '%[EXIF:DateTimeOriginal]|%[EXIF:DateTimeDigitized]|%[EXIF:DateTime]'
        $raw = & $MagickExe identify -quiet -format $fmt -- "$Source" 2>$null
        $taken = $null
        if ($raw) {
            foreach ($cand in ($raw -split '\|')) {
                $c = $cand.Trim()
                if ($c -and $c -ne '0000:00:00 00:00:00') {
                    $dt = [datetime]::MinValue
                    if ([datetime]::TryParseExact($c, 'yyyy:MM:dd HH:mm:ss',
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
                        $taken = $dt
                        break
                    }
                }
            }
        }

        # 2. Ensure destination directory exists.
        $destDir = [System.IO.Path]::GetDirectoryName($Dest)
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # 3. Convert: shrink-only resize (the '>' flag), keep aspect ratio,
        #    apply quality. Metadata (EXIF/XMP/IPTC/ICC) is preserved by default.
        #    Write to a temp name first, then move into place (atomic-ish).
        #    The output format is forced with an explicit CODER: prefix, because
        #    the temp name's extension does not indicate the desired format.
        $tmp = "$Dest.tmp$([System.IO.Path]::GetRandomFileName()).part"
        $coder = $OutExt.ToUpperInvariant()
        $geom = "${MaxPixels}x${MaxPixels}>"
        $mArgs = @("$Source", '-quiet', '-resize', $geom, '-quality', $Quality)
        if ($AvifSpeed -ge 0 -and $OutExt -in @('avif','heic','heif')) {
            # libheif exposes the AV1/HEVC encoder effort under the 'heic:' namespace.
            $mArgs += @('-define', "heic:speed=$AvifSpeed")
        }
        $mArgs += "${coder}:$tmp"
        $stderr = & $MagickExe @mArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            throw "magick failed (exit $LASTEXITCODE): $stderr"
        }

        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
        Move-Item -LiteralPath $tmp -Destination $Dest -Force

        # 4. Stamp file times from the taken date (fall back to source's mtime).
        if (-not $taken) {
            $taken = (Get-Item -LiteralPath $Source).LastWriteTime
        }
        [System.IO.File]::SetCreationTime($Dest, $taken)
        [System.IO.File]::SetLastWriteTime($Dest, $taken)

        $result.Success   = $true
        $result.DestLength = (Get-Item -LiteralPath $Dest).Length
        $result.TakenIso   = $taken.ToString('o')
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Preflight: if an explicit output format was requested, make sure this
# ImageMagick build can actually write it before we do any work.
# ---------------------------------------------------------------------------
if ($OutputFormat -ne 'same') {
    if (-not (Test-MagickCanWrite -Ext $OutputFormat -MagickExe $MagickPath)) {
        $msg = "This ImageMagick build cannot WRITE '$OutputFormat' files."
        if ($OutputFormat -in @('heic','heif')) {
            $msg += "`n  The stock imagemagick.org Windows build reads HEIC but has no HEVC encoder." +
                    "`n  Use -OutputFormat avif for better-than-HEIC compression that works here," +
                    "`n  or install an ImageMagick/libheif build that bundles an x265 HEVC encoder."
        }
        throw $msg
    }
    Write-Host "Output format: .$OutputFormat (verified writable)." -ForegroundColor Cyan
} else {
    Write-Host "Output format: same as each source file." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Load manifest (JSON-lines: one compact JSON object per line). Last line wins
# for a given relative path, which lets us append cheaply and compact later.
# ---------------------------------------------------------------------------
$manifest = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
if ((Test-Path -LiteralPath $ManifestPath) -and -not $FullRefresh) {
    Write-Host "Loading manifest..." -ForegroundColor DarkGray
    foreach ($line in [System.IO.File]::ReadLines($ManifestPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        $manifest[$e.rel] = $e
    }
    Write-Host ("  {0:N0} entries loaded." -f $manifest.Count) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Enumerate source images and classify each as process / skip.
# ---------------------------------------------------------------------------
Write-Host "Scanning source: $SourceFolder" -ForegroundColor Cyan
# Resolve-Path keeps any trailing separator the caller typed ('f:\photos\') and
# always has one for a drive root ('F:\'), so derive the prefix length from a
# normalised copy rather than assuming a separator has to be added.
$srcPrefix = $SourceFolder
if ($srcPrefix[-1] -ne [System.IO.Path]::DirectorySeparatorChar -and
    $srcPrefix[-1] -ne [System.IO.Path]::AltDirectorySeparatorChar) {
    $srcPrefix += [System.IO.Path]::DirectorySeparatorChar
}
$srcPrefixLen = $srcPrefix.Length
$allSourceRel = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$work = [System.Collections.Generic.List[object]]::new()
$skip = 0
$totalSource = 0
$unsupported = 0
$nonImage = 0

# Every file seen lands in exactly one of these buckets, so the scan line always
# reconciles: seen = to process + up to date + non-image + unwritable.
function Format-ScanLine {
    param([long] $Seen, [int] $ToDo, [int] $UpToDate, [int] $NonImage, [int] $Unwritable, [timespan] $Elapsed)
    $other = $NonImage + $Unwritable
    $rate  = if ($Elapsed.TotalSeconds -gt 0) { $Seen / $Elapsed.TotalSeconds } else { 0 }
    return ("{0:N0} files seen = {1:N0} to process + {2:N0} up to date + {3:N0} other  [{4} elapsed, {5:N0} files/s]" -f `
        $Seen, $ToDo, $UpToDate, $other, $Elapsed.ToString('hh\:mm\:ss'), $rate)
}

$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$enum = [System.IO.Directory]::EnumerateFiles($SourceFolder, '*', [System.IO.SearchOption]::AllDirectories)
$seen = 0
foreach ($path in $enum) {
    # Scanning a six-figure library takes a while, so show signs of life. Note
    # that "up to date" usually races to its final value and then sits still,
    # because the folders done on a previous run are enumerated first - hence
    # the elapsed time and file rate, which keep moving either way.
    $seen++
    if (($seen % 200) -eq 0) {
        Write-Progress -Activity "Scanning source" `
            -Status (Format-ScanLine -Seen $seen -ToDo $work.Count -UpToDate $skip -NonImage $nonImage -Unwritable $unsupported -Elapsed $scanSw.Elapsed)
    }
    # Console fallback for hosts that do not render Write-Progress (redirected
    # output, transcripts, ISE).
    if (($seen % 20000) -eq 0) {
        Write-Host ("  " + (Format-ScanLine -Seen $seen -ToDo $work.Count -UpToDate $skip -NonImage $nonImage -Unwritable $unsupported -Elapsed $scanSw.Elapsed)) -ForegroundColor DarkGray
    }

    $ext = [System.IO.Path]::GetExtension($path).TrimStart('.')
    if (-not $extSet.Contains($ext)) { $nonImage++; continue }

    # Determine the output extension for this file and confirm it is writable.
    # ('same' can hit read-only source formats such as HEIC on this build.)
    $outExt = if ($OutputFormat -eq 'same') { $ext.ToLowerInvariant() } else { $OutputFormat }
    if (-not (Test-MagickCanWrite -Ext $outExt -MagickExe $MagickPath)) {
        if ($unsupported -lt 5) {
            Write-Warning ("Skipping (cannot write .{0}): {1}. Use -OutputFormat avif to convert these." -f $outExt, $path)
        }
        $unsupported++
        continue
    }

    $totalSource++
    $rel = $path.Substring($srcPrefixLen)
    [void]$allSourceRel.Add($rel)

    $fi = [System.IO.FileInfo]::new($path)
    $srcWriteTicks = $fi.LastWriteTimeUtc.Ticks
    $dest = Get-DestPath -DestRoot $DestinationFolder -Rel $rel -OutputFormat $OutputFormat

    $need = $true
    if (-not $FullRefresh) {
        $entry = $null
        if ($manifest.TryGetValue($rel, [ref]$entry)) {
            $entryOut = if ($entry.PSObject.Properties['oe']) { [string]$entry.oe } else { $ext.ToLowerInvariant() }
            $entrySp  = if ($entry.PSObject.Properties['sp']) { [int]$entry.sp } else { -1 }
            if ([long]$entry.w -eq $srcWriteTicks -and
                [int]$entry.q  -eq $Quality -and
                [int]$entry.mp -eq $MaxPixels -and
                $entryOut -eq $outExt -and
                $entrySp -eq $AvifSpeed -and
                (Test-Path -LiteralPath $dest)) {
                $need = $false
            }
            # If the output format changed, remove the stale old-extension file.
            if ($entryOut -ne $outExt) {
                $oldDest = Get-DestPath -DestRoot $DestinationFolder -Rel $rel -OutputFormat $entryOut
                if ($oldDest -ne $dest -and (Test-Path -LiteralPath $oldDest)) {
                    Remove-Item -LiteralPath $oldDest -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($need) {
        $work.Add([pscustomobject]@{
            Source = $path
            Dest   = $dest
            Rel    = $rel
            WTicks = $srcWriteTicks
            SLen   = $fi.Length
            OutExt = $outExt
        })
    } else {
        $skip++
    }
}

$scanSw.Stop()
Write-Progress -Activity "Scanning source" -Completed
Write-Host ("  " + (Format-ScanLine -Seen $seen -ToDo $work.Count -UpToDate $skip -NonImage $nonImage -Unwritable $unsupported -Elapsed $scanSw.Elapsed)) -ForegroundColor DarkGray
Write-Host ("Found {0:N0} source images: {1:N0} to process, {2:N0} up to date." -f `
    $totalSource, $work.Count, $skip) -ForegroundColor Cyan
if ($nonImage -gt 0) {
    Write-Host ("  ({0:N0} non-image file(s) ignored.)" -f $nonImage) -ForegroundColor DarkGray
}
if ($unsupported -gt 0) {
    Write-Warning ("{0:N0} file(s) skipped because this build cannot write their format. Use -OutputFormat avif to include them." -f $unsupported)
}

# ---------------------------------------------------------------------------
# ESTIMATE-ONLY mode: sample, compress to temp, extrapolate.
# ---------------------------------------------------------------------------
if ($EstimateOnly) {
    if ($totalSource -eq 0) { Write-Warning "No source images found."; return }

    $n = [Math]::Min($SampleSize, $totalSource)
    $fmtLabel = if ($OutputFormat -eq 'same') { 'same-as-source' } else { ".$OutputFormat" }
    $spLabel  = if ($AvifSpeed -ge 0) { ", AvifSpeed=$AvifSpeed" } else { '' }
    Write-Host "`nEstimating from a random sample of $n image(s) at MaxPixels=$MaxPixels, Quality=$Quality, Format=$fmtLabel$spLabel..." -ForegroundColor Yellow

    # Build the full relative-path list once, then pick a random sample.
    $sampleRel = $allSourceRel | Get-Random -Count $n
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("photolib-est-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    $sumSrc = 0.0; $sumDst = 0.0; $ok = 0
    try {
        $i = 0
        foreach ($rel in $sampleRel) {
            $i++
            Write-Progress -Activity "Sampling" -Status "$i / $n" -PercentComplete (($i / $n) * 100)
            $src = Join-Path $SourceFolder $rel
            $outExt = if ($OutputFormat -eq 'same') { [System.IO.Path]::GetExtension($rel).TrimStart('.') } else { $OutputFormat }
            $dst = Join-Path $tmpRoot ("s$i.$outExt")
            $r = Convert-OneImage -Source $src -Dest $dst -OutExt $outExt -MaxPixels $MaxPixels -Quality $Quality -MagickExe $MagickPath -AvifSpeed $AvifSpeed
            if ($r.Success) {
                $ok++
                $sumSrc += (Get-Item -LiteralPath $src).Length
                $sumDst += $r.DestLength
            }
        }
        Write-Progress -Activity "Sampling" -Completed
    }
    finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($ok -eq 0) { Write-Warning "No sample images could be processed."; return }

    $avgDst = $sumDst / $ok
    $avgSrc = $sumSrc / $ok
    $estTotal = $avgDst * $totalSource
    $ratio = if ($avgSrc -gt 0) { $avgDst / $avgSrc } else { 0 }

    Write-Host ""
    Write-Host "===== ESTIMATE =====" -ForegroundColor Green
    Write-Host ("  Sampled successfully : {0:N0} of {1:N0}" -f $ok, $n)
    Write-Host ("  Avg source size      : {0}" -f (Format-Size $avgSrc))
    Write-Host ("  Avg compressed size  : {0}  ({1:P0} of original)" -f (Format-Size $avgDst), $ratio)
    Write-Host ("  Total source images  : {0:N0}" -f $totalSource)
    Write-Host ("  ESTIMATED destination: {0}" -f (Format-Size $estTotal)) -ForegroundColor Green
    Write-Host "  (Estimate = average compressed size x number of photos; actual will vary.)" -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------------------
# Optional mirror-delete: remove destination files whose source is gone.
# ---------------------------------------------------------------------------
if ($Mirror -and -not $FullRefresh) {
    $toRemove = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in @($manifest.Keys)) {
        if (-not $allSourceRel.Contains($rel)) { $toRemove.Add($rel) }
    }
    if ($toRemove.Count -gt 0) {
        Write-Host ("Mirror: removing {0:N0} orphaned destination file(s)..." -f $toRemove.Count) -ForegroundColor Magenta
        foreach ($rel in $toRemove) {
            $ent = $manifest[$rel]
            $outFmt = if ($ent.PSObject.Properties['oe']) { [string]$ent.oe } else { 'same' }
            $d = Get-DestPath -DestRoot $DestinationFolder -Rel $rel -OutputFormat $outFmt
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
            [void]$manifest.Remove($rel)
        }
        # Rewrite manifest without the removed entries.
        $sw = [System.IO.StreamWriter]::new($ManifestPath, $false)
        try { foreach ($v in $manifest.Values) { $sw.WriteLine(($v | ConvertTo-Json -Compress -Depth 4)) } }
        finally { $sw.Dispose() }
    }
}

if ($FullRefresh -and (Test-Path -LiteralPath $ManifestPath)) {
    Remove-Item -LiteralPath $ManifestPath -Force
}

if ($work.Count -eq 0) {
    Write-Host "Nothing to do. Destination is up to date." -ForegroundColor Green
    # Still report totals below.
}

# ---------------------------------------------------------------------------
# Process in parallel, folder by folder, checkpointing the manifest after each
# chunk. Grouping the work by sub-folder means the console gets a completion
# line at a natural boundary instead of going silent for hours.
# ---------------------------------------------------------------------------
$funcDef = ${function:Convert-OneImage}.ToString()

# Group the queued work by sub-folder, keeping first-seen (enumeration) order.
$folderOrder = [System.Collections.Generic.List[string]]::new()
$byFolder = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($w in $work) {
    $fdir = [System.IO.Path]::GetDirectoryName($w.Rel)
    if (-not $fdir) { $fdir = '.' }
    $bucket = $null
    if (-not $byFolder.TryGetValue($fdir, [ref]$bucket)) {
        $bucket = [System.Collections.Generic.List[object]]::new()
        $byFolder[$fdir] = $bucket
        $folderOrder.Add($fdir)
    }
    $bucket.Add($w)
}

$processed = 0; $failed = 0
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$manifestWriter = [System.IO.StreamWriter]::new($ManifestPath, $true)  # append

if ($work.Count -gt 0) {
    Write-Host ("Processing {0:N0} image(s) across {1:N0} folder(s) with {2} parallel worker(s)..." -f `
        $work.Count, $folderOrder.Count, $ThrottleLimit) -ForegroundColor Cyan
}

try {
    $total = $work.Count
    $folderNo = 0
    $folderTotal = $folderOrder.Count

    foreach ($folderRel in $folderOrder) {
        $folderNo++
        $items = $byFolder[$folderRel]
        $label = if ($folderRel -eq '.') { '<root>' } else { $folderRel }

        $fSw = [System.Diagnostics.Stopwatch]::StartNew()
        $fOk = 0; $fFail = 0; $fSrcBytes = 0.0; $fDstBytes = 0.0

        for ($offset = 0; $offset -lt $items.Count; $offset += $ChunkSize) {
            $end = [Math]::Min($offset + $ChunkSize, $items.Count)
            $chunk = $items.GetRange($offset, $end - $offset)

            $results = $chunk | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                ${function:Convert-OneImage} = $using:funcDef
                $item = $_
                $r = Convert-OneImage -Source $item.Source -Dest $item.Dest -OutExt $item.OutExt `
                        -MaxPixels $using:MaxPixels -Quality $using:Quality -MagickExe $using:MagickPath -AvifSpeed $using:AvifSpeed
                [pscustomobject]@{
                    Rel     = $item.Rel
                    WTicks  = $item.WTicks
                    SLen    = $item.SLen
                    OutExt  = $item.OutExt
                    Success = $r.Success
                    DLen    = $r.DestLength
                    Taken   = $r.TakenIso
                    Error   = $r.Error
                }
            }

            foreach ($r in $results) {
                if ($r.Success) {
                    $processed++; $fOk++
                    $fSrcBytes += [double]$r.SLen
                    $fDstBytes += [double]$r.DLen
                    $entry = [pscustomobject]@{
                        rel = $r.Rel; w = $r.WTicks; sl = $r.SLen
                        dl = $r.DLen; t = $r.Taken; q = $Quality; mp = $MaxPixels; oe = $r.OutExt; sp = $AvifSpeed
                    }
                    $manifest[$r.Rel] = $entry
                    $manifestWriter.WriteLine(($entry | ConvertTo-Json -Compress -Depth 4))
                } else {
                    $failed++; $fFail++
                    Write-Warning ("FAILED: {0} :: {1}" -f $r.Rel, $r.Error)
                }
            }
            $manifestWriter.Flush()

            $done = $processed + $failed
            $rate = if ($sw2.Elapsed.TotalSeconds -gt 0) { $done / $sw2.Elapsed.TotalSeconds } else { 0 }
            $etaSec = if ($rate -gt 0) { ($total - $done) / $rate } else { 0 }
            Write-Progress -Activity "Compressing photos" `
                -Status ("{0:N0}/{1:N0} images | folder {2:N0}/{3:N0}: {4} | {5:N1}/s | ETA {6}" -f `
                    $done, $total, $folderNo, $folderTotal, $label, $rate, ([timespan]::FromSeconds($etaSec).ToString('hh\:mm\:ss'))) `
                -PercentComplete (($done / $total) * 100)

            # A folder big enough to span several chunks would otherwise stay
            # silent until it finished, so tick within it too.
            if ($end -lt $items.Count) {
                Write-Host ("    {0}: {1:N0}/{2:N0} in this folder..." -f $label, $end, $items.Count) -ForegroundColor DarkGray
            }
        }

        $fSw.Stop()
        $ratioTxt = if ($fSrcBytes -gt 0) { '{0:P0}' -f ($fDstBytes / $fSrcBytes) } else { 'n/a' }
        $failTxt  = if ($fFail -gt 0) { ", {0:N0} FAILED" -f $fFail } else { '' }
        $colour   = if ($fFail -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("[{0}/{1}] {2}  {3:N0} image(s){4}  {5} -> {6} ({7})  in {8}" -f `
            $folderNo, $folderTotal, $label, $fOk, $failTxt,
            (Format-Size $fSrcBytes), (Format-Size $fDstBytes), $ratioTxt,
            $fSw.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor $colour

        $doneAll = $processed + $failed
        $rateAll = if ($sw2.Elapsed.TotalSeconds -gt 0) { $doneAll / $sw2.Elapsed.TotalSeconds } else { 0 }
        $etaAll  = if ($rateAll -gt 0) { ($total - $doneAll) / $rateAll } else { 0 }
        Write-Host ("          total {0:N0}/{1:N0} ({2:P0})  {3:N1} img/s  elapsed {4}  ETA {5}" -f `
            $doneAll, $total, ($doneAll / $total), $rateAll,
            $sw2.Elapsed.ToString('hh\:mm\:ss'),
            ([timespan]::FromSeconds($etaAll).ToString('hh\:mm\:ss'))) -ForegroundColor DarkGray
    }
}
finally {
    $manifestWriter.Dispose()
    Write-Progress -Activity "Compressing photos" -Completed
}

# ---------------------------------------------------------------------------
# Compact the manifest (dedupe append history -> one line per file).
# ---------------------------------------------------------------------------
if ($manifest.Count -gt 0) {
    $tmpMan = "$ManifestPath.compact"
    $sw3 = [System.IO.StreamWriter]::new($tmpMan, $false)
    try { foreach ($v in $manifest.Values) { $sw3.WriteLine(($v | ConvertTo-Json -Compress -Depth 4)) } }
    finally { $sw3.Dispose() }
    Move-Item -LiteralPath $tmpMan -Destination $ManifestPath -Force
}

# ---------------------------------------------------------------------------
# Final report + projected full-library size.
# ---------------------------------------------------------------------------
$destBytes = 0.0; $destCount = 0
foreach ($v in $manifest.Values) { $destBytes += [double]$v.dl; $destCount++ }
$avg = if ($destCount -gt 0) { $destBytes / $destCount } else { 0 }
$projected = $avg * $totalSource

$sw2.Stop()
Write-Host ""
Write-Host "===== DONE =====" -ForegroundColor Green
Write-Host ("  Processed this run   : {0:N0}" -f $processed)
Write-Host ("  Skipped (up to date) : {0:N0}" -f $skip)
if ($failed -gt 0) { Write-Host ("  Failed               : {0:N0}" -f $failed) -ForegroundColor Red }
Write-Host ("  Elapsed              : {0}" -f $sw2.Elapsed.ToString('hh\:mm\:ss'))
Write-Host ("  Destination files    : {0:N0}" -f $destCount)
Write-Host ("  Destination size     : {0}" -f (Format-Size $destBytes))
Write-Host ("  Avg compressed size  : {0}" -f (Format-Size $avg))
if ($destCount -lt $totalSource) {
    Write-Host ("  Projected full size  : {0}  (all {1:N0} photos at current avg)" -f (Format-Size $projected), $totalSource) -ForegroundColor Cyan
}
