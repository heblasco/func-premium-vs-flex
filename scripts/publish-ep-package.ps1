#Requires -Version 7.0
<#
.SYNOPSIS
  Uploads an immutable EP package from an authorized private-network executor.
.DESCRIPTION
  Does not apply Terraform or change the app. Prints the hash to set in tfvars.
  Requires installed production dependencies and Blob Data Contributor access.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$InfraPath = (Join-Path $PSScriptRoot '..\infra'),
  [string]$SrcPath = (Join-Path $PSScriptRoot '..\src')
)
$ErrorActionPreference = 'Stop'
$SrcPath = (Resolve-Path $SrcPath).Path
if (-not (Test-Path (Join-Path $SrcPath 'node_modules\@azure\functions'))) {
  throw 'Production dependencies are missing. Run scripts\build.ps1 first.'
}
$json = terraform "-chdir=$((Resolve-Path $InfraPath).Path)" output -json elastic_premium
if ($LASTEXITCODE -ne 0) { throw 'EP bootstrap outputs are unavailable.' }
$ep = $json | ConvertFrom-Json
if (-not $ep.storage_account) { throw 'Enable EP bootstrap resources before uploading.' }
if (-not $PSCmdlet.ShouldProcess($ep.storage_account, 'Upload private immutable EP deployment package')) { return }
$output = Join-Path $SrcPath 'artifacts'
[void](New-Item -ItemType Directory -Force -Path $output)
$temporaryZip = Join-Path $output "$([guid]::NewGuid()).zip"
try {
  $archive = [System.IO.Compression.ZipFile]::Open($temporaryZip, 'Create')
  try {
    $files = @(
      Get-Item (Join-Path $SrcPath 'host.json'), (Join-Path $SrcPath 'package.json'), (Join-Path $SrcPath 'package-lock.json')
      Get-ChildItem (Join-Path $SrcPath 'src'), (Join-Path $SrcPath 'node_modules') -File -Recurse -Force
    )
    foreach ($file in $files) {
      $relative = [System.IO.Path]::GetRelativePath($SrcPath, $file.FullName).Replace('\', '/')
      [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative, 'Optimal')
    }
  } finally { $archive.Dispose() }
  $hash = (Get-FileHash $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
  $blob = "$hash.zip"
  & az storage blob upload --account-name $ep.storage_account --container-name $ep.container --name $blob `
    --file $temporaryZip --auth-mode login --overwrite false --only-show-errors -o none
  if ($LASTEXITCODE -ne 0) {
    throw 'Upload failed (including if the immutable blob already exists). Check private DNS/network access and Blob Data Contributor RBAC. No firewall/key fallback is attempted.'
  }
  Write-Host "Set ep_package_sha256 = `"$hash`" in terraform.tfvars, then review/apply Terraform."
  Write-Host 'After apply, sync triggers through ARM and verify startup before the settling period.'
} finally {
  if (Test-Path -LiteralPath $temporaryZip) { Remove-Item -LiteralPath $temporaryZip -Force }
}
