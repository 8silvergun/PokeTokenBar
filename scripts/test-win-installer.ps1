# Run only on a disposable Windows CI runner: this exercises the per-user installer registration.
param(
  [Parameter(Mandatory)][string]$Installer,
  [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') {
  throw 'Installer integration test is restricted to disposable GitHub Actions runners.'
}
$testRoot = Join-Path $env:TEMP "ptb install test $([guid]::NewGuid().ToString('N'))"
$installDir = Join-Path $testRoot 'Installed App'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$oldPath = $env:PATH
$oldState = $env:PTB_STATE_DIR
$wslConfig = Join-Path $env:APPDATA 'PokeTokenBar\wsl-distro.txt'
$tray = $null
$primaryFailure = $null
$cleanupFailure = $null
function Invoke-CheckedProcess([string]$File, [string[]]$Arguments, [int]$Timeout = 180000) {
  Write-Host "Starting: $File (timeout ${Timeout}ms)"
  $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
  try {
    if (-not $process.WaitForExit($Timeout)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Process timed out: $File"
    }
    if ($process.ExitCode -ne 0) { throw "Process failed ($($process.ExitCode)): $File" }
  } finally { $process.Dispose() }
}
try {
  Invoke-CheckedProcess (Resolve-Path -LiteralPath $Installer).Path @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    "/DIR=`"$installDir`"", "/LOG=`"$testRoot\install.log`"")
  $exe = Join-Path $installDir 'PokeTokenBar.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw 'Installed EXE missing' }
  if (-not (Test-Path -LiteralPath $wslConfig)) {
    throw 'Installer did not persist the WSL distribution selection file'
  }
  $env:PATH = "$env:WINDIR\System32;$env:WINDIR"
  $env:PTB_STATE_DIR = Join-Path $testRoot 'state'
  $versionFile = Join-Path $testRoot 'installed version.txt'
  Invoke-CheckedProcess $exe @('--version-file', "`"$versionFile`"") 15000
  if ((Get-Content -LiteralPath $versionFile -Raw).Trim() -ne $Version) {
    throw 'Installed application version mismatch'
  }
  # Starting without diagnostic flags exercises the real tray entry point, not just DLL loading.
  $tray = Start-Process -FilePath $exe -PassThru
  if ($tray.WaitForExit(5000)) { throw "Tray exited during startup: $($tray.ExitCode)" }
  # A second launch should exit rather than create a second tray instance.
  Invoke-CheckedProcess $exe @('--tray') 15000
  Write-Host 'Installed application: clean-PATH version, tray lifetime and single-instance probes passed.'
} catch {
  $primaryFailure = $_
  Write-Host "Primary failure: $($_.Exception.Message)"
} finally {
  try {
  if ($tray) {
    if (-not $tray.HasExited) { $tray.Kill(); $tray.WaitForExit() }
    $tray.Dispose()
  }
  $env:PATH = $oldPath
  $env:PTB_STATE_DIR = $oldState
  if (Test-Path -LiteralPath $wslConfig) {
    Remove-Item -LiteralPath $wslConfig -Force -ErrorAction SilentlyContinue
  }
  $uninstaller = Join-Path $installDir 'unins000.exe'
  if (Test-Path -LiteralPath $uninstaller) {
    Invoke-CheckedProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$testRoot\uninstall.log`"")
    if (Test-Path -LiteralPath (Join-Path $installDir 'PokeTokenBar.exe')) {
      throw 'Uninstall left the application executable behind'
    }
  }
  } catch {
    $cleanupFailure = $_
    Write-Host "Cleanup failure: $($_.Exception.Message)"
  } finally {
    $env:PATH = $oldPath
    $env:PTB_STATE_DIR = $oldState
  }
  foreach ($log in @('install.log', 'uninstall.log')) {
    $logPath = Join-Path $testRoot $log
    if (Test-Path -LiteralPath $logPath) {
      Write-Host "::group::$log"
      Get-Content -LiteralPath $logPath -Tail 100
      Write-Host '::endgroup::'
    }
  }
  Write-Host "Integration-test logs retained at: $testRoot"
}
if ($primaryFailure) { throw $primaryFailure }
if ($cleanupFailure) { throw $cleanupFailure }
