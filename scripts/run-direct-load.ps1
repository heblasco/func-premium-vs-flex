<#
.SYNOPSIS
  Drives identical parallel load against the Flex and Premium apps directly from
  the operator machine (no Azure Load Testing engines).
.DESCRIPTION
  Useful when the deployer IP is allow-listed on the apps (deployer_allow_cidr)
  and you want immediate, reproducible results + App Insights telemetry without
  provisioning VNet-injected load engines. Spins up N concurrent workers PER app
  using a runspace pool; every worker loops calling /api/stress until the
  deadline and records latency / status. Both apps are hit at the same time so
  the comparison is fair.
.PARAMETER Workers   Concurrent workers PER app. Default 12.
.PARAMETER Duration  Total hold seconds. Default 120.
.PARAMETER CpuMs     Busy-loop ms per invocation. Default 300.
.PARAMETER MemMB     Memory allocated per invocation (MB). Default 128.
.PARAMETER Loops     CPU+mem loops per invocation. Default 2.
#>
[CmdletBinding()]
param(
  [int]$Workers  = 12,
  [int]$Duration = 120,
  [int]$CpuMs    = 300,
  [int]$MemMB    = 128,
  [int]$Loops    = 2,
  [string]$InfraPath = (Join-Path $PSScriptRoot '..\infra')
)

$ErrorActionPreference = 'Stop'
$InfraPath = (Resolve-Path $InfraPath).Path

Write-Host "Reading Terraform outputs..." -ForegroundColor Cyan
Push-Location $InfraPath
try { $tf = terraform output -json | ConvertFrom-Json } finally { Pop-Location }

$rg       = $tf.resource_group_name.value
$flexApp  = $tf.flex_app_name.value
$premApp  = $tf.premium_app_name.value
$flexHost = $tf.flex_default_hostname.value
$premHost = $tf.premium_default_hostname.value

Write-Host "Fetching function keys..." -ForegroundColor Cyan
$flexKey = az functionapp keys list -g $rg -n $flexApp --query "functionKeys.default" -o tsv
$premKey = az functionapp keys list -g $rg -n $premApp --query "functionKeys.default" -o tsv
if (-not $flexKey -or -not $premKey) { throw "Could not retrieve function keys." }

$runId = "direct-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "runId = $runId  (use this to correlate in App Insights / KQL)" -ForegroundColor Yellow

$targets = @(
  @{ plan = 'flex';    host = $flexHost; key = $flexKey },
  @{ plan = 'premium'; host = $premHost; key = $premKey }
)

$worker = {
  param($uriBase, $key, $deadline, $plan)
  $res = [pscustomobject]@{ plan = $plan; ok = 0; err = 0; totalMs = 0.0; maxMs = 0.0 }
  $h = @{ 'x-functions-key' = $key }
  while ([DateTime]::UtcNow -lt $deadline) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      Invoke-WebRequest -Uri $uriBase -Headers $h -UseBasicParsing -TimeoutSec 120 | Out-Null
      $sw.Stop(); $res.ok++
      $res.totalMs += $sw.Elapsed.TotalMilliseconds
      if ($sw.Elapsed.TotalMilliseconds -gt $res.maxMs) { $res.maxMs = $sw.Elapsed.TotalMilliseconds }
    } catch {
      $sw.Stop(); $res.err++
    }
  }
  return $res
}

$deadline = [DateTime]::UtcNow.AddSeconds($Duration)
$pool = [runspacefactory]::CreateRunspacePool(1, ($Workers * 2) + 4)
$pool.Open()
$handles = @()

Write-Host "Launching $Workers workers x 2 apps for ${Duration}s (cpuMs=$CpuMs memMB=$MemMB loops=$Loops)..." -ForegroundColor Cyan
foreach ($t in $targets) {
  $uri = "https://$($t.host)/api/stress?cpuMs=$CpuMs&memMB=$MemMB&loops=$Loops&runId=$runId-$($t.plan)"
  for ($i = 0; $i -lt $Workers; $i++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($uri).AddArgument($t.key).AddArgument($deadline).AddArgument($t.plan)
    $handles += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
  }
}

Write-Host "Running... waiting for workers to finish." -ForegroundColor Cyan
$results = foreach ($h in $handles) { $h.ps.EndInvoke($h.handle); $h.ps.Dispose() }
$pool.Close()

Write-Host "`n================ RESULTS (runId=$runId) ================" -ForegroundColor Green
$summary = $results | Group-Object plan | ForEach-Object {
  $ok  = ($_.Group | Measure-Object ok  -Sum).Sum
  $err = ($_.Group | Measure-Object err -Sum).Sum
  $tot = ($_.Group | Measure-Object totalMs -Sum).Sum
  $max = ($_.Group | Measure-Object maxMs -Maximum).Maximum
  [pscustomobject]@{
    Plan        = $_.Name
    Requests    = $ok + $err
    Success     = $ok
    Errors      = $err
    'Avg ms'    = if ($ok) { [math]::Round($tot / $ok, 0) } else { 0 }
    'Max ms'    = [math]::Round($max, 0)
    'Req/s'     = [math]::Round(($ok + $err) / $Duration, 2)
  }
}
$summary | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Correlate telemetry in App Insights using runId prefix '$runId'." -ForegroundColor Yellow
