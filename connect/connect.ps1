<#
.SYNOPSIS
  Connect to a DSH instance running on a remote machine (Windows client).

.DESCRIPTION
  Does the same three things as connect/connect.sh:
    1. asks the remote to start (or reuse) `dsh web`
    2. opens an SSH tunnel  localhost:<LocalPort> -> remote 127.0.0.1:<RemotePort>
    3. opens the tokenized URL in your browser

  The remote side must have been set up with install-remote.sh first.

.EXAMPLE
  .\connect.ps1 -RemoteHost my-devbox

.EXAMPLE
  .\connect.ps1 -RemoteHost 203.0.113.10 -SshPort 2222 -User root -LocalPort 9000
#>
param(
  [Parameter(Mandatory = $true)][string]$RemoteHost,
  [int]$SshPort = 0,
  [string]$User = "",
  [string]$Key = "",
  [int]$LocalPort = 8787,
  [int]$RemotePort = 8787,
  [string]$RemoteScript = '$HOME/.dsh-remote-workspace/start-web.sh',
  [switch]$NoBrowser
)

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

$target = if ($User) { "$User@$RemoteHost" } else { $RemoteHost }

$sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
if ($SshPort -gt 0) { $sshOpts += @('-p', "$SshPort") }
if ($Key) { $sshOpts += @('-i', $Key) }

# 1) remote: make sure dsh web is running, get its URL
Info "asking $target to start (or reuse) dsh web"
$remoteCmd = "bash $RemoteScript $RemotePort"
$raw = & ssh @sshOpts $target $remoteCmd 2>$null
if ($LASTEXITCODE -ne 0 -and -not $raw) {
  Fail "could not reach $target. Try manually: ssh $target `"$remoteCmd`""
}
$url = ($raw | Where-Object { $_ -match 'token=' } | Select-Object -Last 1)
if (-not $url) {
  Fail @"
could not get a URL from the remote.
  check the install:   ssh $target "ls -l $RemoteScript"
  or re-run:           ./install-remote.sh --host $RemoteHost
"@
}
$url = $url.Trim()

# 2) local tunnel
$listening = Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue
if ($listening) {
  Info "localhost:$LocalPort already listening, reusing the tunnel"
} else {
  Info "opening tunnel localhost:$LocalPort -> $target`:127.0.0.1:$RemotePort"
  $tunnelArgs = @('-N', '-L', "$LocalPort`:127.0.0.1:$RemotePort") + $sshOpts + @($target)
  Start-Process ssh -ArgumentList $tunnelArgs -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue) { break }
  }
  if (-not (Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue)) {
    Fail "tunnel did not come up on port $LocalPort"
  }
}

$localUrl = if ($LocalPort -ne $RemotePort) { $url -replace ":$RemotePort/", ":$LocalPort/" } else { $url }

Write-Host ""
Write-Host "  open : $localUrl" -ForegroundColor Green
Write-Host ""

if (-not $NoBrowser) { Start-Process $localUrl }

Write-Host "The tunnel stays in the background. To close it, stop the 'ssh -N' process."
