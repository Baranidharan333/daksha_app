# Builds the Windows app and, if Inno Setup is installed, an installer.
#   powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1
#     -> build\windows\x64\runner\Release\daksha.exe   (portable folder)
#     -> build\windows-installer\daksha_<version>_setup.exe
# Needs: Flutter, Visual Studio 2022 with "Desktop development with C++",
# and optionally Inno Setup 6 (https://jrsoftware.org/isinfo.php).
# The web view uses Microsoft Edge WebView2, preinstalled on up-to-date Windows 10/11.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value

Write-Host '==> flutter build windows --release'
flutter build windows --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Bundle = Join-Path $Root 'build\windows\x64\runner\Release'
Write-Host "Built $Bundle\daksha.exe"

$Iscc = @(
  (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($Iscc) {
  Write-Host '==> Inno Setup'
  & $Iscc "/DAppVersion=$Version" packaging\daksha.iss
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "Built build\windows-installer\daksha_${Version}_setup.exe"
} else {
  Write-Host 'Inno Setup not found; skipping installer. Zip the Release folder to ship it portable.'
}
