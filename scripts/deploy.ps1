<#
.SYNOPSIS
  Publishes the shared Node.js function code to BOTH the Flex and Premium apps.
.DESCRIPTION
  Reads app names from `terraform output` and uses Azure Functions Core Tools
  (`func azure functionapp publish`). Requires the deployer public IP to be
  allow-listed on the function SCM endpoint (handled by Terraform via
  deployer_ipv4 / auto-discovery).
#>
[CmdletBinding()]
param(
  [string]$InfraPath = (Join-Path $PSScriptRoot '..\infra'),
  [string]$SrcPath   = (Join-Path $PSScriptRoot '..\src')
)

$ErrorActionPreference = 'Stop'
$InfraPath = (Resolve-Path $InfraPath).Path
$SrcPath   = (Resolve-Path $SrcPath).Path

Write-Host "Reading Terraform outputs..." -ForegroundColor Cyan
Push-Location $InfraPath
try {
  $tf = terraform output -json | ConvertFrom-Json
} finally {
  Pop-Location
}

$flexApp    = $tf.flex_app_name.value
$premiumApp = $tf.premium_app_name.value

if (-not $flexApp -or -not $premiumApp) {
  throw "Could not read app names from terraform output. Run 'terraform apply' first."
}

# Ensure dependencies are present.
& (Join-Path $PSScriptRoot 'build.ps1') -SrcPath $SrcPath

Push-Location $SrcPath
try {
  foreach ($app in @($flexApp, $premiumApp)) {
    Write-Host "`nPublishing to $app ..." -ForegroundColor Cyan
    func azure functionapp publish $app --javascript --no-build
    if ($LASTEXITCODE -ne 0) { throw "func publish failed for $app" }
  }
  Write-Host "`nDeployment complete for both apps." -ForegroundColor Green
} finally {
  Pop-Location
}
