# Build the Windows installer (Setup.exe) for PokeTokenBar from the current release build.
#
#   pwsh scripts/build-win-installer.ps1 -Version 2.5.3 -OutDir out
#
# Prerequisites:
#   * `swift build -c release` already run in the Swift-for-Windows environment (produces the exe).
#   * Inno Setup installed: winget install JRSoftware.InnoSetup
#
# Optional release signing:
#   * Set PTB_SIGNING_CERT_SHA1 to the SHA-1 thumbprint of a code-signing certificate installed in
#     the current user's certificate store. When set, both the portable EXE and Setup EXE are signed
#     and verified with signtool. A configured signing request fails closed if signing cannot complete.
#
# It assembles the portable folder (release exe + Swift runtime DLLs + VC++ runtime) and compiles
# installer/PokeTokenBar.iss into PokeTokenBar-Setup-<Version>.exe (per-user AppData installer).
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
  [string]$OutDir = "."
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root ".build\x86_64-unknown-windows-msvc\release\PokeTokenBar.exe"
if (-not (Test-Path $exe)) {
  throw "Release exe not found - run 'swift build -c release' first: $exe"
}

# Check the baked version only AFTER staging the runtime. A raw EXE may not start without its DLLs.

# setup-swift adds the active toolchain, runtime and ICU usr/bin directories to PATH. Prefer those
# active directories instead of guessing a particular local/hosted installation layout.
$swiftExe = (Get-Command swift.exe -ErrorAction Stop).Source
$toolchainBin = Split-Path $swiftExe -Parent
# Both setup-swift and the official installer place Toolchains and Runtimes under one root.
$toolchainsMarker = '\Toolchains\'
$markerIndex = $swiftExe.IndexOf($toolchainsMarker, [StringComparison]::OrdinalIgnoreCase)
if ($markerIndex -lt 0) { throw "Unsupported Swift installation layout: $swiftExe" }
$swiftRoot = $swiftExe.Substring(0, $markerIndex)
$swiftPrefix = $swiftRoot.TrimEnd('\') + '\'
$candidateDirs = New-Object System.Collections.Generic.List[string]

function Add-CandidateDir([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
  if (-not $resolved -or -not $resolved.StartsWith($swiftPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    return # Never copy DLLs from System32, PHP, or a different Swift installation.
  }
  if ($resolved -and -not $candidateDirs.Contains($resolved)) {
    $candidateDirs.Add($resolved)
  }
}

Add-CandidateDir $toolchainBin

# Discover runtime/toolchain/ICU directories exported by the active Swift setup. Restrict candidates
# to directories that actually contain known Swift runtime components so unrelated PATH DLLs are not
# bundled into the application.
$pathDirs = @($env:PATH -split [Regex]::Escape([string][System.IO.Path]::PathSeparator)) |
  Where-Object { $_ } |
  Select-Object -Unique
foreach ($dir in $pathDirs) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
  $hasKnownRuntime =
    (Test-Path -LiteralPath (Join-Path $dir "FoundationNetworking.dll")) -or
    (Test-Path -LiteralPath (Join-Path $dir "Foundation.dll")) -or
    (Test-Path -LiteralPath (Join-Path $dir "swiftCore.dll")) -or
    (Test-Path -LiteralPath (Join-Path $dir "BlocksRuntime.dll")) -or
    (Test-Path -LiteralPath (Join-Path $dir "dispatch.dll")) -or
    (@(Get-ChildItem -LiteralPath $dir -Filter "icu*.dll" -File -ErrorAction SilentlyContinue).Count -gt 0)
  if ($hasKnownRuntime) {
    Add-CandidateDir $dir
  }
}

# Also support the official local Swift installer layout even when its Runtime/bin is not currently
# present in PATH.
$localRuntimeRoot = Join-Path $swiftRoot "Runtimes"
if (Test-Path -LiteralPath $localRuntimeRoot) {
  Get-ChildItem -LiteralPath $localRuntimeRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Add-CandidateDir (Join-Path $_.FullName "usr\bin") }
}

# Pick the runtime directory that contains FoundationNetworking and Foundation together. This pair is
# the minimum trustable signal that we found the real Swift Windows runtime rather than a tool bin.
$runtimeDir = $candidateDirs |
  Where-Object {
    (Test-Path -LiteralPath (Join-Path $_ "FoundationNetworking.dll")) -and
    (Test-Path -LiteralPath (Join-Path $_ "Foundation.dll"))
  } |
  Select-Object -First 1

if (-not $runtimeDir) {
  $runtimeDir = $candidateDirs |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ "FoundationNetworking.dll") } |
    Select-Object -First 1
}

# Fallback discovery stays inside the selected Swift installation.
if (-not $runtimeDir) {
  Write-Host "Searching for FoundationNetworking.dll under: $swiftRoot"
  $found = Get-ChildItem -LiteralPath $swiftRoot -Filter "FoundationNetworking.dll" -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($found) {
    $runtimeDir = $found.DirectoryName
    Add-CandidateDir $runtimeDir
  }
}

if (-not $runtimeDir) {
  Write-Host "Active PATH runtime candidates:"
  $candidateDirs | ForEach-Object { Write-Host "  $_" }
  throw "Could not locate FoundationNetworking.dll for the active Swift toolchain: $swiftExe"
}

Write-Host "Active Swift: $swiftExe"
Write-Host "Swift runtime DLL directory: $runtimeDir"
Write-Host "Swift dependency directories:"
$candidateDirs | ForEach-Object { Write-Host "  $_" }

$stage = Join-Path $env:TEMP "ptb-portable-$Version-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item $exe $stage

# The primary runtime directory establishes the Foundation/Swift DLL set. Then supplement missing DLLs
# from other active Swift PATH directories (notably toolchain and ICU dirs) without overwriting the
# primary runtime's versions.
$runtimeDlls = @(Get-ChildItem -LiteralPath $runtimeDir -Filter "*.dll" -File -ErrorAction Stop)
if ($runtimeDlls.Count -eq 0) {
  throw "No Swift runtime DLLs found in: $runtimeDir"
}
$runtimeDlls | Copy-Item -Destination $stage -Force

foreach ($dir in $candidateDirs) {
  if ($dir -eq $runtimeDir) { continue }
  foreach ($dll in @(Get-ChildItem -LiteralPath $dir -Filter "*.dll" -File -ErrorAction SilentlyContinue)) {
    # Toolchain directories also contain compiler/IDE DLLs; those are not application runtimes.
    if ($dll.Name -notmatch '^(BlocksRuntime|dispatch|icu[^\\]*|libcurl[^\\]*|libxml2[^\\]*|libssl[^\\]*|libcrypto[^\\]*|zlib[^\\]*)\.dll$') { continue }
    $target = Join-Path $stage $dll.Name
    if (-not (Test-Path -LiteralPath $target)) {
      Copy-Item -LiteralPath $dll.FullName -Destination $target
    }
  }
}

$stagedDlls = @(Get-ChildItem -LiteralPath $stage -Filter '*.dll' -File)
Write-Host "Staged DLL count: $($stagedDlls.Count); bytes: $(($stagedDlls | Measure-Object Length -Sum).Sum)"
if (Test-Path -LiteralPath (Join-Path $stage 'kernel32.dll')) {
  throw 'Packaging regression: Windows system DLLs must not be bundled.'
}

# VC++ runtime is normally present on supported Windows machines, but bundle the common DLLs when the
# runner/developer machine has them so the installer is self-contained for clean machines as well.
foreach ($d in @("VCRUNTIME140.dll", "VCRUNTIME140_1.dll", "msvcp140.dll")) {
  $source = "C:\Windows\System32\$d"
  if (Test-Path $source) {
    Copy-Item $source $stage -Force
  }
}

# Fail closed if the exact DLL that caused the clean-machine startup failure is not staged. Foundation
# itself is also required by FoundationNetworking, so assert both before creating an installer.
foreach ($required in @("Foundation.dll", "FoundationNetworking.dll")) {
  if (-not (Test-Path (Join-Path $stage $required))) {
    throw "Required Swift runtime DLL missing from staged package: $required"
  }
}

# Smoke-test the staged folder with Swift/toolchain directories removed from PATH. This approximates a
# clean end-user machine and catches transitive missing runtime DLLs before an installer is built.
$oldPath = $env:PATH
$probeExit = $null
$versionFile = Join-Path $stage "baked-version.txt"
$probe = $null
try {
  $minimalPath = @(
    $stage,
    (Join-Path $env:WINDIR "System32"),
    $env:WINDIR
  ) -join ";"
  $env:PATH = $minimalPath
  $probe = Start-Process -FilePath (Join-Path $stage "PokeTokenBar.exe") `
    -ArgumentList @('--version-file', "`"$versionFile`"") -PassThru
  if (-not $probe.WaitForExit(15000)) {
    $probe.Kill()
    throw "Staged executable timed out while reading the baked version."
  }
  $probeExit = $probe.ExitCode
} finally {
  $env:PATH = $oldPath
  if ($probe) { $probe.Dispose() }
}
if ($null -eq $probeExit -or $probeExit -ne 0) {
  throw "Staged Windows executable failed the clean-PATH runtime smoke test (exit $probeExit). Stage: $stage"
}
if (-not (Test-Path -LiteralPath $versionFile) -or
    (Get-Content -LiteralPath $versionFile -Raw).Trim() -ne $Version) {
  throw "Staged Windows executable did not report the expected baked version v$Version."
}
Remove-Item -LiteralPath $versionFile
Write-Host "Runtime smoke test passed with clean PATH."

$signingThumbprint = $env:PTB_SIGNING_CERT_SHA1
$signtool = $null
if ($signingThumbprint) {
  $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
  if (-not $signtool) {
    throw "PTB_SIGNING_CERT_SHA1 is set but signtool.exe was not found."
  }
}

function Invoke-CodeSign([string]$Path) {
  if (-not $signingThumbprint) { return }
  Write-Host "Signing: $Path"
  & $signtool sign /sha1 $signingThumbprint /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 $Path
  if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed: $Path" }
  & $signtool verify /pa /all $Path
  if ($LASTEXITCODE -ne 0) { throw "Authenticode verification failed: $Path" }
}

# Sign the exact application EXE that will be embedded in the installer.
Invoke-CodeSign (Join-Path $stage "PokeTokenBar.exe")

$iscc = Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup 6", "${env:ProgramFiles(x86)}\Inno Setup 6", "$env:ProgramFiles\Inno Setup 6" -Filter ISCC.exe -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $iscc) {
  throw "ISCC.exe (Inno Setup) not found. Install: winget install JRSoftware.InnoSetup"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
& $iscc "/DSrcDir=$stage" "/DAppVer=$Version" "/DOutDir=$OutDir" (Join-Path $root "installer\PokeTokenBar.iss")
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed."
}

$installer = Join-Path $OutDir "PokeTokenBar-Setup-$Version.exe"
if (-not (Test-Path $installer)) {
  throw "Expected installer was not produced: $installer"
}
Invoke-CodeSign $installer

if (-not $signingThumbprint) {
  Write-Warning "Windows artifacts are UNSIGNED. Set PTB_SIGNING_CERT_SHA1 for public release builds."
}
Write-Host "Installer: $(Resolve-Path $installer)"
