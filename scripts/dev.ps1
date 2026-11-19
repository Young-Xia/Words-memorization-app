param([ValidateSet('check','run','build')][string]$Action = 'check')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$flutterBin = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutterBin)) {
  $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
  if (!$flutterCommand) { throw 'Flutter SDK missing. Install Flutter or place it at .tools/flutter.' }
  $flutterBin = $flutterCommand.Source
}
Set-Location -LiteralPath $projectRoot
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
& $flutterBin pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Action -eq 'check') {
  & $flutterBin analyze
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $flutterBin test
} elseif ($Action -eq 'run') {
  & $flutterBin run -d windows
} else {
  & $flutterBin build windows --release --no-tree-shake-icons
}
exit $LASTEXITCODE
