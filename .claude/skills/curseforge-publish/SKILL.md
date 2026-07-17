# CurseForge Publish Workflow

## Overview

Use this skill when preparing a WoW addon release artifact for CurseForge or similar distribution sites.

For TalonTracker, the release workflow is atomic: bump version and package in one pass.

## When to use this skill

Use this skill when the user asks to:

- prepare a new publish zip
- bump version for release
- verify release archive contents
- perform final pre-upload checks

## TalonTracker atomic release steps

1. Update version in both files:
   - TalonTracker.toc: `## Version: x.y.z`
   - Core.lua: `TT.VERSION = "x.y.z"`
2. Update TOC interface value for the current target client flavor.
3. Build archive immediately after bump:
   - output: `dist/TalonTracker-vx.y.z.zip`
   - zip root folder: `TalonTracker/`
4. Include only runtime files listed by TalonTracker.toc, plus README.md and LICENSE.
5. Exclude dev-only content such as `.git`, `.claude`, `.agent`, `screenshots`, `scripts`, and temporary staging folders.
6. Validate zip entries before completion.

## Validation checklist

- TOC and runtime Lua version match.
- Archive filename matches TOC/Core version.
- TOC interface value is current.
- Archive installs by extracting into Interface/AddOns.
- No dev-only files are present.

## Notes

- Prefer deterministic packaging from TOC file list rather than wildcard folder zips.
- If upload itself is requested, explain that web upload is manual unless a separate authenticated upload pipeline exists.

## Proven PowerShell scripts (TalonTracker)

Use these exact commands for repeatable release packaging.

### Preferred: package without creating dist/TalonTracker

This keeps working tree noise low and avoids leaving a staging folder in git changes.

```powershell
$ErrorActionPreference = "Stop"
$repo = Get-Location
$tocPath = Join-Path $repo "TalonTracker.toc"

$versionLine = Select-String -Path $tocPath -Pattern '^## Version:\s*(.+)$'
if (-not $versionLine) { throw "Could not find version in TalonTracker.toc" }
$version = $versionLine.Matches[0].Groups[1].Value.Trim()

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("TalonTracker-release-" + [guid]::NewGuid())
$stageRoot = Join-Path $tempRoot "TalonTracker"
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

try {
   Copy-Item -LiteralPath $tocPath -Destination (Join-Path $stageRoot "TalonTracker.toc") -Force

   $tocEntries = Get-Content -LiteralPath $tocPath | Where-Object {
      $line = $_.Trim()
      $line -and -not $line.StartsWith("##")
   }

   foreach ($entry in $tocEntries) {
      $source = Join-Path $repo $entry
      if (-not (Test-Path -LiteralPath $source)) { throw "Missing TOC entry source: $entry" }

      $dest = Join-Path $stageRoot $entry
      $destDir = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      Copy-Item -LiteralPath $source -Destination $dest -Force
   }

   $zipPath = Join-Path $repo ("dist/TalonTracker-v{0}.zip" -f $version)
   if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
   Compress-Archive -Path $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force

   Write-Output ("Created: {0}" -f $zipPath)
}
finally {
   if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
   }
}
```

### Alternate: package via dist/TalonTracker staging

Use only if explicit on-disk staging is desired.

```powershell
$ErrorActionPreference = "Stop"
$repo = Get-Location
$tocPath = Join-Path $repo "TalonTracker.toc"

$versionLine = Select-String -Path $tocPath -Pattern '^## Version:\s*(.+)$'
if (-not $versionLine) { throw "Could not find version in TalonTracker.toc" }
$version = $versionLine.Matches[0].Groups[1].Value.Trim()

$stageRoot = Join-Path $repo "dist/TalonTracker"
if (Test-Path $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

Copy-Item -LiteralPath $tocPath -Destination (Join-Path $stageRoot "TalonTracker.toc") -Force
$tocEntries = Get-Content -LiteralPath $tocPath | Where-Object {
   $line = $_.Trim()
   $line -and -not $line.StartsWith("##")
}

foreach ($entry in $tocEntries) {
   $source = Join-Path $repo $entry
   if (-not (Test-Path -LiteralPath $source)) { throw "Missing TOC entry source: $entry" }

   $dest = Join-Path $stageRoot $entry
   $destDir = Split-Path -Parent $dest
   if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
   Copy-Item -LiteralPath $source -Destination $dest -Force
}

$zipPath = Join-Path $repo ("dist/TalonTracker-v{0}.zip" -f $version)
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force
Write-Output ("Created: {0}" -f $zipPath)
```

### Validate archive entries

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tocPath = "TalonTracker.toc"
$versionLine = Select-String -Path $tocPath -Pattern '^## Version:\s*(.+)$'
if (-not $versionLine) { throw "Could not find version in TalonTracker.toc" }
$version = $versionLine.Matches[0].Groups[1].Value.Trim()
$zipPath = Resolve-Path ("dist/TalonTracker-v{0}.zip" -f $version)
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
   $zip.Entries | Select-Object -ExpandProperty FullName
}
finally {
   $zip.Dispose()
}
```

### Optional cleanup for staged builds

```powershell
if (Test-Path "dist/TalonTracker") {
   Remove-Item -LiteralPath "dist/TalonTracker" -Recurse -Force
}
```
