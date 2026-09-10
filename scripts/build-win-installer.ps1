# Build the Windows installer (Setup.exe) for PokeTokenBar from the current release build.
#
#   pwsh scripts/build-win-installer.ps1 -Version 2.4.5.7 -OutDir out
#   pwsh scripts/build-win-installer.ps1 -Version 2.4.5.7 -OutDir out -RequireSigning
#
# Prerequisites:
#   * `swift build -c release` already run in the Swift-for-Windows environment (produces the exe).
#   * Inno Setup installed:  winget install JRSoftware.InnoSetup
#   * For signed releases: a code-signing certificate in the CurrentUser/My certificate store and
#     PTB_SIGNING_CERT_THUMBPRINT set to its SHA-1 thumbprint. The certificate/private key is NEVER
#     stored in this repository.
#
# It assembles the portable folder (release exe + Swift runtime DLLs + VC++ runtime) and compiles
# installer/PokeTokenBar.iss into PokeTokenBar-Setup-<Version>.exe (per-user AppData installer).
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$OutDir = ".",
  [string]$SigningThumbprint = $env:PTB_SIGNING_CERT_THUMBPRINT,
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$RequireSigning
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root ".build\x86_64-unknown-windows-msvc\release\PokeTokenBar.exe"
if (-not (Test-Path $exe)) { throw "Release exe not found - run 'swift build -c release' first: $exe" }

# Guard: the built exe's baked version MUST match -Version. Forgetting `swift build -c release` after
# bumping the version silently ships a stale exe (e.g. Setup-2.4.5.13 containing a 2.4.5.12 binary =>
# an endless update loop). Verify before packaging.
$baked = (& $exe --update-check 2>&1 | Select-String 'current baked version:\s*([\d.]+)').Matches.Groups[1].Value
if ($baked -ne $Version) {
  throw "Release exe is v$baked but you asked for v$Version. Run 'swift build -c release' after bumping WindowsUpdate.currentVersion, then retry."
}

function Find-SignTool {
  $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (-not (Test-Path $kits)) { return $null }
  return Get-ChildItem $kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}

$thumb = ($SigningThumbprint -replace '\s', '').ToUpperInvariant()
if ($thumb -and $thumb -notmatch '^[0-9A-F]{40}$') {
  throw "Signing thumbprint must be a 40-character SHA-1 certificate thumbprint."
}
if ($RequireSigning -and -not $thumb) {
  throw "A signed release was required but PTB_SIGNING_CERT_THUMBPRINT/-SigningThumbprint is empty."
}
$signTool = if ($thumb) { Find-SignTool } else { $null }
if ($thumb -and -not $signTool) { throw "signtool.exe not found in the Windows 10/11 SDK." }

function Sign-And-Verify([string]$Path) {
  if (-not $thumb) { return }
  & $signTool sign /sha1 $thumb /fd SHA256 /tr $TimestampUrl /td SHA256 $Path
  if ($LASTEXITCODE -ne 0) { throw "signtool failed for $Path" }
  $sig = Get-AuthenticodeSignature -LiteralPath $Path
  $actual = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint.ToUpperInvariant() } else { "" }
  if ($sig.Status -ne 'Valid' -or $actual -ne $thumb) {
    throw "Authenticode verification failed for $Path (status=$($sig.Status), signer=$actual)."
  }
}

# Swift runtime (redistributable DLLs) + toolchain bin (BlocksRuntime/dispatch).
$rt = (Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName + "\usr\bin"
$tc = (Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName + "\usr\bin"

$stage = Join-Path $env:TEMP "ptb-portable-$Version"
if (Test-Path $stage) { Get-ChildItem $stage | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$stagedExe = Join-Path $stage "PokeTokenBar.exe"
Copy-Item $exe $stagedExe
Copy-Item (Join-Path $rt "*.dll") $stage -Force
foreach ($d in "BlocksRuntime.dll", "dispatch.dll") { $s = Join-Path $tc $d; if (Test-Path $s) { Copy-Item $s $stage -Force } }
foreach ($d in "VCRUNTIME140.dll", "VCRUNTIME140_1.dll", "msvcp140.dll") { $s = "C:\Windows\System32\$d"; if (Test-Path $s) { Copy-Item $s $stage -Force } }

# Sign the application binary before it is embedded in the installer.
Sign-And-Verify $stagedExe

$iscc = Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup 6", "${env:ProgramFiles(x86)}\Inno Setup 6", "$env:ProgramFiles\Inno Setup 6" -Filter ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $iscc) { throw "ISCC.exe (Inno Setup) not found. Install: winget install JRSoftware.InnoSetup" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
& $iscc "/DSrcDir=$stage" "/DAppVer=$Version" "/DOutDir=$OutDir" (Join-Path $root "installer\PokeTokenBar.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

$installer = Resolve-Path (Join-Path $OutDir "PokeTokenBar-Setup-$Version.exe")
# Sign the final container too; the runtime updater pins this same certificate thumbprint.
Sign-And-Verify $installer.Path

# Always emit a checksum next to the installer. This is useful for manual verification and release
# provenance, while Authenticode signer pinning remains the trust anchor for unattended execution.
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.Path).Hash.ToLowerInvariant()
$checksumPath = "$($installer.Path).sha256"
"$hash  $([IO.Path]::GetFileName($installer.Path))" | Set-Content -Encoding ascii -NoNewline $checksumPath

if (-not $thumb) {
  Write-Warning "Unsigned development installer built. Auto-update will refuse unattended execution until WindowsUpdate.trustedInstallerSignerThumbprint is configured."
}
Write-Host "Installer: $installer"
Write-Host "SHA-256:  $checksumPath"
