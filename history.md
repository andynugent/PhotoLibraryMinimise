# Project history

A running log of the prompts that shaped this project and the changes made in
response to each. Newest entries are added at the bottom.

---

## 1. Initial request — create the compression script

**Prompt (summary):** I have 100,000+ photos (~300 GB). I want a local (no-cloud)
script (PowerShell preferred, Python acceptable) that creates compressed/reduced
copies with all metadata retained and the file created/modified time set to the
image's taken time. It must be re-runnable to pick up new images, remember the
source timestamp so edited photos (e.g. GPS added) get re-exported, support a max
pixel size (downscale larger, never upscale, keep aspect ratio), a JPEG quality
setting, an estimate of the destination size, a full-refresh option, and preserve
the sub-folder structure and filenames.

**Changes:**
- Created **`Compress-PhotoLibrary.ps1`** (PowerShell 7 + ImageMagick 7):
  - Recursive scan; mirrors sub-folders and filenames to the destination.
  - Shrink-only resize (`NxN>`) with aspect ratio preserved; configurable
    `-MaxPixels` and `-Quality`.
  - Metadata preserved by ImageMagick; file created/modified time stamped from EXIF
    `DateTimeOriginal` → `Digitized` → `DateTime`, falling back to source mtime.
  - Re-runnable via a JSON-lines manifest (`.photolib-manifest.jsonl`) keyed by
    relative path, storing source last-write time (as ticks), size and settings;
    reprocesses on new/changed/edited files or changed settings.
  - `-EstimateOnly` samples images, compresses them, and extrapolates a total size.
  - `-FullRefresh` rebuild; optional `-Mirror` to delete orphaned copies.
  - Parallelised with `ForEach-Object -Parallel`; manifest checkpointed per chunk.
- Verified end-to-end on generated test images (resize, EXIF/GPS retention,
  timestamping, skip/re-run, setting-change detection, full refresh, mirror).

## 2. HEIC input + smaller-than-JPEG output

**Prompt:** Handle `.heic` input images. My phone (Android Pixel 7a) handles
`.heic`; add an option to save the destination images as `.heic` for better
compression than JPEG.

**Changes:**
- Found the installed ImageMagick can **read** HEIC but **cannot write** it (no HEVC
  encoder); it **can** read/write **AVIF**, which compresses better than HEIC and
  displays natively on the Pixel 7a.
- Added **`-OutputFormat`** (`same` | `jpg` | `avif` | `heic` | `webp` | `png` | `jxl`
  | `tiff`) to `Compress-PhotoLibrary.ps1`:
  - Preflight writability check that rejects unsupported output formats early, with a
    clear message pointing to AVIF for the HEIC case.
  - Output format forced with an explicit coder prefix (fixes a bug where the temp
    filename made ImageMagick silently inherit the source format).
  - Output format tracked in the manifest, so changing format reprocesses and the
    stale old-extension file is cleaned up.
  - `-EstimateOnly` respects the chosen output format.
- Verified AVIF output (real format, downscale, EXIF + timestamps), HEIC-write
  rejection, and format-switch reprocessing/cleanup.

## 3. Portable ImageMagick downloader

**Prompt:** Create a script to download the latest (or a fixed version) ImageMagick
with libheif into this folder, so the scripts can get their dependency on any system
without changing what's installed.

**Changes:**
- Created **`Get-PortableImageMagick.ps1`**:
  - Resolves the official portable build from GitHub Releases
    (`ImageMagick/ImageMagick`), `latest` or a pinned `-Version`, architecture-aware.
  - Downloads the portable `.7z` and extracts it with the Windows-bundled `tar.exe`
    (bsdtar/libarchive reads 7-Zip) — no 7-Zip and no install needed.
  - Verifies `magick.exe` runs and reports the HEIC + AVIF delegates; prints/enforces
    a SHA-256; records the version; makes no PATH/registry changes.
- Updated `Compress-PhotoLibrary.ps1` to auto-detect `tools\ImageMagick\magick.exe`
  (no `-MagickPath` needed) and to print which ImageMagick it is using.
- Verified: downloaded ImageMagick 7.1.2-29, extracted, confirmed HEIC read + AVIF
  write, and the main script used it automatically.

## 4. Minimal (trimmed) portable build

**Prompt:** yes *(to the offered `-Minimal` trimming option)*.

**Changes:**
- Added **`-Minimal`** to `Get-PortableImageMagick.ps1`: deletes the 7 redundant
  standalone utility exes (each a ~30 MB static copy) since `magick.exe` performs all
  of them via subcommands. Cuts the folder from ~240 MB to ~32 MB. Works both after a
  fresh download and in-place on an already-installed copy (no re-download).
- Verified the trim (freed 208 MB) and that a full conversion still works with the
  `magick.exe`-only build (including the `magick identify` subcommand).

## 5. Self-bootstrapping main script

**Prompt:** Update the main script to run `Get-PortableImageMagick.ps1` if the tools
folder doesn't exist.

**Changes:**
- `Compress-PhotoLibrary.ps1` now auto-runs `Get-PortableImageMagick.ps1 -Minimal`
  when no portable ImageMagick is present, then uses it; falls back to `magick` on
  PATH if the download fails.
- Added **`-NoDownload`** to skip auto-download and use PATH instead.
- Verified: with no `tools` folder the compressor downloaded + trimmed + processed in
  one run; `-NoDownload` used the system `magick` without downloading.

## 6. Documentation + history

**Prompt:** Update `README.md` with instructions for the scripts, and create a
`history.md` with the prompts I've given and the changes made because of them, and
automatically update both in future with any changes.

**Changes:**
- Wrote **`README.md`** (overview, requirements, quick start, full parameter tables
  for both scripts, change-detection explanation, output-format/HEIC-vs-AVIF notes,
  sizing guide, caveats).
- Created this **`history.md`**.
- Standing agreement: keep `README.md` and `history.md` updated as part of any future
  change to this project.

## 7. GPU acceleration question + `-AvifSpeed` knob

**Prompt:** The laptop with the photos is 6 core / 12 thread with an NVIDIA GTX 1050.
Is there an ImageMagick build that does the AVIF compression on the GPU to speed it up?
*(then)* Yes, add the `-AvifSpeed` knob.

**Changes:**
- Explained (with a benchmark) that GPU AVIF acceleration is not available: the GTX
  1050 (Pascal) has no hardware AV1 encoder — those only exist on RTX 40-series and
  newer — and ImageMagick's AVIF path (libheif + libaom) is CPU-only regardless. The
  real speed/size lever is the encoder effort setting.
- Added **`-AvifSpeed`** (`-1`=encoder default/fast … `0`=slowest/smallest,
  `9`=fastest) to `Compress-PhotoLibrary.ps1`, passed as `-define heic:speed=N` for
  AVIF/HEIC output only. Tracked in the manifest so changing it reprocesses; shown in
  the `-EstimateOnly` header. Documented the speed-vs-size trade-off in the README.
- Verified: default ~1s/image, `-AvifSpeed 3` ~25s/image (smaller), a speed change
  triggers reprocessing, and an unchanged re-run skips.

## 8. Bug fix — trailing separator on `-SourceFolder` truncated sub-folder names

**Prompt:** There's a bug that the output folder is missing the first character of
the sub-folder: processing `f:\photos` → `f:\photos.phone` gave
`f:\photos\Amazon` → `f:\photos.phone\Mazon`.

**Changes:**
- Fixed the relative-path calculation in `Compress-PhotoLibrary.ps1`. It used
  `$SourceFolder.Length + 1` as the prefix length to strip, which assumed the
  resolved source path never ends in a separator. `Resolve-Path` keeps a trailing
  `\` if the caller typed one (`f:\photos\`), and a drive root (`F:\`) always has
  one, so the `+ 1` consumed the first character of every relative path — hence
  `Amazon` → `Mazon`. The prefix length is now derived from a normalised copy of
  the source path that has exactly one trailing separator, so `F:\photos`,
  `F:\photos\` and `F:\` all yield `Amazon\pic.jpg`.
- Note for existing runs: the affected manifest entries and destination files carry
  the truncated names. Re-running with `-Mirror` deletes them as orphans and writes
  the correct paths; without `-Mirror`, remove the mis-named destination folders by
  hand (or use `-FullRefresh`).

## 9. Standing rule — suggest a commit message

**Prompt:** Add a standing rule to output a suggested commit comment of the changes
that have been made — ideally a short title and a 1-3 line summary/description.

**Changes:**
- No script changes. Recorded the standing agreement: every set of changes now ends
  with a suggested commit message (short imperative title + 1-3 line description) in
  a copyable code block. It is a suggestion only — nothing is committed unless asked.
