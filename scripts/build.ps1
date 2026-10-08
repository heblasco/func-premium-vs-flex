<#
.SYNOPSIS
  Installs production dependencies for the Node.js function app.
#>
[CmdletBinding()]
param(
  [string]$SrcPath = (Join-Path $PSScriptRoot '..\src')
)

$ErrorActionPreference = 'Stop'
$SrcPath = (Resolve-Path $SrcPath).Path
Write-Host "Installing dependencies in $SrcPath ..." -ForegroundColor Cyan

Push-Location $SrcPath
try {
  if (Test-Path 'package-lock.json') {
    npm ci --omit=dev
  } else {
    npm install --omit=dev
  }
  Write-Host "Build/install complete." -ForegroundColor Green
} finally {
  Pop-Location
}
