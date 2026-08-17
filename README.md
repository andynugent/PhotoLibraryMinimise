# PhotoLibraryMinimise

Keep a full, offline copy of a large photo library (100k+ photos, hundreds of GB)
on your phone **without a cloud service**, by generating size-reduced copies that:

- **retain all metadata** (EXIF / XMP / IPTC / ICC, including GPS),
- **mirror the source folder structure and filenames**,
- have their **file created/modified time set to the photo's "date taken"**,
- are **downscaled** to a maximum pixel size (aspect ratio preserved, never upscaled),
- are compressed to a format/quality you choose (JPEG, or **AVIF** for much smaller files).

The tool is **re-runnable**: on each run it processes only new or changed photos, so
you can point it at a growing library repeatedly. It can also **estimate the total
destination size** before you commit to a full run.

---

## Contents

| File | Purpose |
|------|---------|
| `Compress-PhotoLibrary.ps1` | Main script: scans the source, makes reduced copies, tracks state. |
| `Get-PortableImageMagick.ps1` | Downloads a portable ImageMagick (no system install) into `tools\`. |
| `tools\ImageMagick\` | The portable ImageMagick (auto-created; git-ignored). |
| `<destination>\.photolib-manifest.jsonl` | State file that records what has been processed. |

---

## Requirements

- **Windows** with **PowerShell 7+** (`pwsh`). Check with `$PSVersionTable.PSVersion`.
- **ImageMagick 7** — you do **not** need to install it. On first run the main script
  auto-downloads a portable copy into `tools\ImageMagick\` (see below). A system-wide
  ImageMagick on `PATH` also works.
- Windows 10/11 bundled `tar.exe` (used to unpack the portable download). Present by default.

No installation, PATH, or registry changes are made. Delete the folder to remove everything.

---

## Quick start

```powershell
# 1. (Optional) Estimate the destination size first:
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" `
    -MaxPixels 2048 -Quality 60 -OutputFormat avif -EstimateOnly

# 2. Do the real run (re-run this same command any time to pick up new/changed photos):
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" `
    -MaxPixels 2048 -Quality 60 -OutputFormat avif
```

On the very first run, if no portable ImageMagick is present, the script downloads one
automatically (~31 MB) before starting. Subsequent runs reuse it.

---

## `Compress-PhotoLibrary.ps1`

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SourceFolder` | *(required)* | Root of the original library. Never modified. |
| `-DestinationFolder` | *(required)* | Root for the reduced copies. Created if missing. |
| `-MaxPixels` | `2048` | Longest-edge limit in pixels. Larger images shrink to fit; smaller are left untouched; aspect ratio preserved. |
| `-Quality` | `85` | Encoder quality 1–100. Scales differ per codec — AVIF ~55–63 ≈ JPEG ~85 visually, at a fraction of the size. |
| `-OutputFormat` | `same` | `same` keeps each source's format/extension. Or force one: `jpg`, `avif`, `heic`*, `webp`, `png`, `jxl`, `tiff`. Base filename is kept; extension changes. |
| `-FullRefresh` | off | Ignore the manifest and reprocess everything, overwriting the destination. |
| `-EstimateOnly` | off | Don't process; sample images, measure average compressed size, and report an estimated total. Nothing is written to the destination. |
| `-SampleSize` | `60` | Number of images to sample for `-EstimateOnly`. |
| `-Mirror` | off | Also delete destination files whose source no longer exists (exact mirror). |
| `-Extensions` | common photo types | Source extensions to include (jpg, jpeg, png, tif, tiff, heic, heif, webp, bmp…). |
| `-ThrottleLimit` | CPU cores | Parallel worker count. |
| `-ChunkSize` | `500` | Files processed between manifest checkpoints (crash-safe/resumable). |
| `-MagickPath` | auto | Explicit path to `magick.exe`. If omitted, uses the portable copy / auto-download / PATH. |
| `-NoDownload` | off | Do not auto-download a portable ImageMagick; use `magick` on PATH instead. |

\* `heic` output requires an ImageMagick build with an HEVC **encoder**, which the
official distribution does **not** include. See **Output format notes** below.

### How change-detection works

State is recorded in `<destination>\.photolib-manifest.jsonl` (one JSON line per file).
A source photo is (re)processed when any of these is true:

- it is new, or its destination file is missing;
- the source's last-modified time changed (e.g. you edited GPS/EXIF);
- `-MaxPixels`, `-Quality`, or `-OutputFormat` differ from when it was last made
  (a format change also cleans up the stale old-extension file);
- `-FullRefresh` is used.

### Examples

```powershell
# Keep source formats, just shrink + recompress (JPEG stays JPEG, PNG stays PNG):
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" -MaxPixels 2048 -Quality 85

# Convert everything to AVIF (smallest; Android/Pixel displays it natively):
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" -MaxPixels 2048 -Quality 60 -OutputFormat avif

# Exact mirror (also removes copies whose originals were deleted):
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" -OutputFormat avif -Mirror

# Full rebuild:
.\Compress-PhotoLibrary.ps1 -SourceFolder "D:\Photos" -DestinationFolder "E:\PhoneCopy" -FullRefresh
```

Full help: `Get-Help .\Compress-PhotoLibrary.ps1 -Full`

---

## `Get-PortableImageMagick.ps1`

Downloads the official **portable** ImageMagick (a self-contained build including
libheif for HEIC reading and libaom for AVIF) from GitHub Releases and unpacks it into
`tools\ImageMagick\` using the Windows-bundled `tar.exe` — **no 7-Zip and no install
required**. The main script calls this automatically when needed, but you can also run
it directly.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Version` | `latest` | `latest`, or a pinned release tag like `7.1.2-29` for reproducibility. |
| `-Quantum` | `Q16-HDRI` | Build variant (`Q16-HDRI`, `Q16`, or `Q8`). |
| `-DestinationRoot` | `.\tools` | Where the `ImageMagick` folder is created. |
| `-ExpectedSha256` | none | If set, the download must match this SHA-256 or it aborts. The computed hash is always printed. |
| `-Minimal` | off | Delete the 7 redundant standalone utility exes (magick.exe does their jobs). Cuts ~240 MB → ~32 MB. Also works on an existing install without re-downloading. |
| `-Force` | off | Re-download even if a working copy already exists. |

### Examples

```powershell
.\Get-PortableImageMagick.ps1                       # newest release into .\tools\ImageMagick
.\Get-PortableImageMagick.ps1 -Minimal              # newest, trimmed to ~32 MB
.\Get-PortableImageMagick.ps1 -Version 7.1.2-29 -Minimal   # pinned + trimmed
.\Get-PortableImageMagick.ps1 -Minimal              # trim an existing copy in place
```

Architecture (x64 / arm64 / x86) is detected automatically.

---

## Output format notes

The installed/portable ImageMagick reads `.heic` fine, but its format support is:

| Format | Read | Write |
|--------|:----:|:-----:|
| HEIC   | yes  | **no** (no HEVC encoder in the official build) |
| AVIF   | yes  | **yes** |
| JPEG / PNG / WebP / TIFF | yes | yes |
| JXL    | yes  | yes |

**For a phone copy, AVIF is the recommended output**: it compresses better than both JPEG
and HEIC, is royalty-free, and displays natively on modern Android (Pixel 7a included).
`.heic` output is only possible with a custom ImageMagick/libheif build that bundles an
HEVC (x265) encoder.

### Rough sizing guide

At `-MaxPixels 2048`, a typical photo lands around:

- **JPEG q85** — ~0.5–1.5 MB each (~50–150 GB for 100k photos)
- **AVIF q55–63** — often 30–60% smaller than the JPEG for similar visual quality

Always run `-EstimateOnly` against **your** library for a real number before a full run.

---

## Notes & caveats

- **AVIF encoding is CPU-heavy** (AV1). It parallelises across all cores but is slower
  per image than JPEG — fine for an overnight run, just not JPEG-fast.
- The run is **resumable**: the manifest is checkpointed every `-ChunkSize` files, so an
  interruption only re-does the current chunk.
- First real run: try it on **one sub-folder** (a few hundred photos) to confirm quality,
  size, and orientation look right on your phone before processing the whole library.
