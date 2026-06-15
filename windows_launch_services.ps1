#Requires -RunAsAdministrator
<# 
.SYNOPSIS
    K8s Home Lab startup script.
    Run this every time the Windows machine boots before connecting from your Mac.
.NOTES
    Must be run as Administrator.
    Usage: .\Start-K8sLab.ps1
#>

$MetalLBIP = "10.55.55.150"
$SSHPort   = 2222

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  K8s Home Lab - Startup Script" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# ─── STEP 1: Start WSL2 SSH daemon ───────────────────────────────────────────
Write-Host "[1/4] Starting WSL2 SSH daemon..." -ForegroundColor Yellow
wsl -e sudo service ssh start | Out-Null

# Verify it started
$sshStatus = wsl -e sudo service ssh status
if ($sshStatus -match "running") {
    Write-Host "      SSH daemon is running." -ForegroundColor Green
} else {
    Write-Host "      WARNING: SSH daemon may not have started. Check WSL2 manually." -ForegroundColor Red
}

Write-Host ""

# ─── STEP 2: Fix port proxy ───────────────────────────────────────────────────
Write-Host "[2/4] Updating port proxy with current WSL2 IP..." -ForegroundColor Yellow

# Get the first IP only (ignore k3s cluster IPs)
$wslIP = (wsl hostname -I).Trim().Split()[0]
Write-Host "      WSL2 IP: $wslIP" -ForegroundColor Gray

# Reset and recreate all port proxy rules
netsh interface portproxy reset | Out-Null

netsh interface portproxy add v4tov4 listenport=$SSHPort listenaddress=0.0.0.0 connectport=$SSHPort connectaddress=$wslIP | Out-Null
netsh interface portproxy add v4tov4 listenport=80    listenaddress=0.0.0.0 connectport=80    connectaddress=$MetalLBIP | Out-Null
netsh interface portproxy add v4tov4 listenport=443   listenaddress=0.0.0.0 connectport=443   connectaddress=$MetalLBIP | Out-Null

Write-Host "      Port proxy rules set:" -ForegroundColor Green
Write-Host "        0.0.0.0:2222 → $wslIP:2222  (SSH)" -ForegroundColor Gray
Write-Host "        0.0.0.0:80   → $MetalLBIP:80   (HTTP ingress)" -ForegroundColor Gray
Write-Host "        0.0.0.0:443  → $MetalLBIP:443  (HTTPS ingress)" -ForegroundColor Gray

Write-Host ""

# ─── STEP 3: Ensure firewall rules exist ─────────────────────────────────────
Write-Host "[3/4] Checking firewall rules..." -ForegroundColor Yellow

$rules = @(
    @{ Name = "wsl-ssh";   DisplayName = "WSL2 SSH";  Port = 2222 },
    @{ Name = "k8s-http";  DisplayName = "K8s HTTP";  Port = 80   },
    @{ Name = "k8s-https"; DisplayName = "K8s HTTPS"; Port = 443  }
)

foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "      $($rule.DisplayName) rule already exists." -ForegroundColor Green
    } else {
        New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName `
            -Enabled True -Direction Inbound -Protocol TCP `
            -Action Allow -LocalPort $rule.Port | Out-Null
        Write-Host "      $($rule.DisplayName) rule created (port $($rule.Port))." -ForegroundColor Green
    }
}

Write-Host ""

# ─── STEP 4: Verify SSH is reachable ─────────────────────────────────────────
Write-Host "[4/4] Testing SSH connectivity on port $SSHPort..." -ForegroundColor Yellow

$tcpTest = Test-NetConnection -ComputerName "127.0.0.1" -Port $SSHPort -WarningAction SilentlyContinue
if ($tcpTest.TcpTestSucceeded) {
    Write-Host "      SSH port $SSHPort is reachable." -ForegroundColor Green
} else {
    Write-Host "      WARNING: SSH port $SSHPort is not responding. Check the WSL2 SSH daemon." -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  All done. Connect from your Mac with:" -ForegroundColor Cyan
Write-Host "  ssh rob@10.55.55.30 -p 2222" -ForegroundColor White
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""