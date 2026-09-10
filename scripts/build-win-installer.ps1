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
  [Parameter(Mandatory)][string]$Version,
  [string]$OutDir = "."
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root ".build\x86_64-unknown-windows-msvc\release\PokeTokenBar.exe"
if (-not (Test-Path $exe)) {
  throw "Release exe not found - run 'swift build -c release' first: $exe"
}

# Guard: the built exe's baked version MUST match -Version. Forgetting `swift build -c release` after
# bumping the version can ship a stale binary and cause an endless update loop.
$bakedOutput = @(& $exe --update-check 2>&1)
$bakedMatch = $bakedOutput | Select-String 'current baked version:\s*([\d.]+)' | Select-Object -First 1
if (-not $bakedMatch) {
  throw "Could not read the baked version from PokeTokenBar.exe --update-check."
}
$baked = $bakedMatch.Matches.Groups[1].Value
if ($baked -ne $Version) {
  throw "Release exe is v$baked but you asked for v$Version. Run 'swift build -c release' after bumping WindowsUpdate.currentVersion, then retry."
}

# Discover runtime DLLs from the ACTIVE Swift installation instead of assuming the Windows installer
# layout under %LOCALAPPDATA%. This supports both the official local installer and GitHub Actions
# toolchains installed under C:\hostedtoolcache by setup-swift.
$swiftExe = (Get-Command swift.exe -ErrorAction Stop).Source
$toolchainBin = Split-Path $swiftExe -Parent
$runtimeDirs = New-Object System.Collections.Generic.List[string]

function Add-RuntimeDir([string]$Path) {
  if ($Path -and (Test-Path $Path) -and -not $runtimeDirs.Contains($Path)) {
    $runtimeDirs.Add($Path)
  }
}

# The active toolchain bin is cheap to check and may itself contain redistributable DLLs.
Add-RuntimeDir $toolchainBin

# If the active swift.exe lives below a Toolchains directory, its installation root is the path
# immediately before \Toolchains\. Both the local Swift installer and setup-swift use this shape.
$swiftInstallRoot = $null
$marker = "\Toolchains\"
$markerIndex = $swiftExe.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
if ($markerIndex -ge 0) {
  $swiftInstallRoot = $swiftExe.Substring(0, $markerIndex)
}

# Prefer explicit Runtime directories when they exist.
$localRuntimeRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"
if (Test-Path $localRuntimeRoot) {
  Get-ChildItem $localRuntimeRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Add-RuntimeDir (Join-Path $_.FullName "usr\bin") }
}

if ($swiftInstallRoot) {
  $runtimeRoot = Join-Path $swiftInstallRoot "Runtimes"
  if (Test-Path $runtimeRoot) {
    Get-ChildItem $runtimeRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      ForEach-Object { Add-RuntimeDir (Join-Path $_.FullName "usr\bin") }
  }
}

# Find the directory containing FoundationNetworking.dll. If no direct candidate has it, do one
# bounded fallback search inside the active Swift installation root. The exact layout differs between
# local Swift installers and hosted CI toolchains.
$runtimeDir = $runtimeDirs |
  Where-Object { Test-Path (Join-Path $_ "FoundationNetworking.dll") } |
  Select-Object -First 1

if (-not $runtimeDir -and $swiftInstallRoot -and (Test-Path $swiftInstallRoot)) {
  Write-Host "Searching active Swift installation for FoundationNetworking.dll: $swiftInstallRoot"
  $foundationNetworking = Get-ChildItem $swiftInstallRoot -Filter "FoundationNetworking.dll" -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($foundationNetworking) {
    $runtimeDir = $foundationNetworking.DirectoryName
    Add-RuntimeDir $runtimeDir
  }
}

if (-not $runtimeDir) {
  throw "Could not locate FoundationNetworking.dll for the active Swift toolchain: $swiftExe"
}

Write-Host "Active Swift: $swiftExe"
Write-Host "Swift runtime DLL directory: $runtimeDir"

$stage = Join-Path $env:TEMP "ptb-portable-$Version"
if (Test-Path $stage) {
  Remove-Item $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item $exe $stage

# Copy the complete redistributable runtime directory so transitive Foundation/Swift dependencies are
# kept together. This is intentionally broader than copying only FoundationNetworking.dll.
$runtimeDlls = @(Get-ChildItem $runtimeDir -Filter "*.dll" -File -ErrorAction Stop)
if ($runtimeDlls.Count -eq 0) {
  throw "No Swift runtime DLLs found in: $runtimeDir"
}
$runtimeDlls | Copy-Item -Destination $stage -Force

# BlocksRuntime.dll and dispatch.dll can live in the active toolchain bin rather than Runtime/bin.
foreach ($d in @("BlocksRuntime.dll", "dispatch.dll")) {
  $source = Join-Path $toolchainBin $d
  if (-not (Test-Path $source) -and $swiftInstallRoot -and (Test-Path $swiftInstallRoot)) {
    $found = Get-ChildItem $swiftInstallRoot -Filter $d -File -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($found) { $source = $found.FullName }
  }
  if (Test-Path $source) {
    Copy-Item $source $stage -Force
  }
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

# Smoke-test the staged folder with the toolchain directories removed from PATH. This approximates a
# clean end-user machine and catches missing adjacent Swift runtime DLLs before an installer is built.
$oldPath = $env:PATH
try {
  $minimalPath = @(
    $stage,
    (Join-Path $env:WINDIR "System32"),
    $env:WINDIR
  ) -join ";"
  $env:PATH = $minimalPath
  $probeOutput = @(& (Join-Path $stage "PokeTokenBar.exe") --update-check 2>&1)
  $probeExit = $LASTEXITCODE
} finally {
  $env:PATH = $oldPath
}
if ($probeExit -ne 0) {
  throw "Staged Windows executable failed the clean-PATH runtime smoke test (exit $probeExit): $($probeOutput -join ' ')"
}
$probeMatch = $probeOutput | Select-String 'current baked version:\s*([\d.]+)' | Select-Object -First 1
if (-not $probeMatch -or $probeMatch.Matches.Groups[1].Value -ne $Version) {
  throw "Staged Windows executable did not report the expected baked version v$Version."
}
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
