#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) "ep-package-test-$([guid]::NewGuid())"
$global:EpPackageTest = @{ Uploaded = $false; FailUpload = $false }

function terraform {
  $global:LASTEXITCODE = 0
  '{"storage_account":"teststore","container":"deploymentpackage"}'
}

function az {
  $global:LASTEXITCODE = if ($global:EpPackageTest.FailUpload) { 1 } else { 0 }
  $arguments = @($args)
  $file = $arguments[$arguments.IndexOf('--file') + 1]
  $blob = $arguments[$arguments.IndexOf('--name') + 1]
  if ($arguments[$arguments.IndexOf('--auth-mode') + 1] -ne 'login') { throw 'Expected keyless upload.' }
  if ($arguments[$arguments.IndexOf('--overwrite') + 1] -ne 'false') { throw 'Expected immutable upload.' }
  if ($blob -ne "$((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()).zip") { throw 'Incorrect blob hash.' }
  $zip = [System.IO.Compression.ZipFile]::OpenRead($file)
  try {
    $names = @($zip.Entries.FullName)
    foreach ($required in @('host.json','package.json','package-lock.json','src/functions/stress.js','node_modules/@azure/functions/package.json')) {
      if ($names -notcontains $required) { throw "Missing ZIP entry: $required" }
    }
    if ($names | Where-Object { $_ -match 'local.settings|secret|test/|artifacts/' }) { throw 'Unexpected deployment content.' }
  } finally { $zip.Dispose() }
  $global:EpPackageTest.Uploaded = $true
}

try {
  [void](New-Item -ItemType Directory -Path "$fixture\src\functions", "$fixture\node_modules\@azure\functions", "$fixture\test")
  foreach ($file in @('host.json','package.json','package-lock.json','node_modules\@azure\functions\package.json')) {
    Set-Content -LiteralPath (Join-Path $fixture $file) -Value '{}'
  }
  Set-Content -LiteralPath "$fixture\src\functions\stress.js" -Value '// fixture'
  Set-Content -LiteralPath "$fixture\local.settings.json" -Value 'secret'
  Set-Content -LiteralPath "$fixture\test\secret.txt" -Value 'secret'
  $publisher = Join-Path $PSScriptRoot '..\publish-ep-package.ps1'
  $infra = Join-Path $PSScriptRoot '..\..\infra'
  & $publisher -SrcPath $fixture -InfraPath $infra -WhatIf
  if ($global:EpPackageTest.Uploaded) { throw 'WhatIf uploaded data.' }
  & $publisher -SrcPath $fixture -InfraPath $infra -Confirm:$false
  if (-not $global:EpPackageTest.Uploaded) { throw 'Package was not uploaded.' }
  if (Get-ChildItem "$fixture\artifacts" -File) { throw 'Temporary ZIP was not removed.' }
  $global:EpPackageTest.FailUpload = $true
  $failed = $false
  try { & $publisher -SrcPath $fixture -InfraPath $infra -Confirm:$false } catch { $failed = $true }
  if (-not $failed) { throw 'Upload failure was not surfaced.' }
  if (Get-ChildItem "$fixture\artifacts" -File) { throw 'Failed upload left a temporary ZIP.' }
  Write-Output 'PASS: package layout, exclusions, SHA256 name, keyless immutable upload, WhatIf and failure cleanup.'
} finally {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
  Remove-Variable EpPackageTest -Scope Global
}
