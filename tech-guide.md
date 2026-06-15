# Technical Guide — Scripts Reference

All scripts in execution order. Cross-referenced with README.md phases.

---

## Phase 1 — Windows Initial Setup

> Run in **PowerShell as Administrator** on the Windows host.

### `install_ubuntu.ps1` — Install WSL2 + Ubuntu 22.04

```powershell
wsl --install -d Ubuntu-22.04
```

Restart Windows after this completes. On reboot, Ubuntu will launch automatically and prompt for a UNIX username and password.

---

### `enable_ssh.ps1` — Enable Windows Native OpenSSH Server (optional)

Installs the Windows OpenSSH server feature, sets it to start automatically, and opens port 22 in the firewall. Only needed if you want to SSH directly into Windows (not WSL).

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
# Allow through firewall
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

---

## Phase 2 — WSL2 SSH Configuration

> Run inside WSL2 (Ubuntu). Open WSL by typing `wsl` in a Windows terminal, or connect via `wsl.exe` from PowerShell.

### `config_ssh_daemon.sh` — Install and Configure SSH Daemon in WSL2

Installs `openssh-server`, drops a config snippet that sets port 2222 and enables password auth, then starts the service.

```bash
sudo apt-get update && sudo apt-get install -y openssh-server

sudo tee /etc/ssh/sshd_config.d/wsl.conf > /dev/null <<'EOF'
Port 2222
PasswordAuthentication yes
EOF

sudo service ssh start
```

Port 2222 is used to avoid conflicting with the Windows OpenSSH server on port 22.

---

## Phase 3 — Windows Port Forwarding (one-time)

> Run inside WSL2. The script calls back into `powershell.exe` to set Windows-side rules.

### `windows_port_forward.sh` — Create Port Proxy and Firewall Rule

Reads the current WSL2 IP, then uses `netsh` to proxy Windows port 2222 to WSL port 2222, and creates a firewall inbound rule.

```bash
WSL_IP=$(hostname -I | awk '{print $1}')
powershell.exe -Command "netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$WSL_IP"
powershell.exe -Command "New-NetFirewallRule -Name wsl-ssh -DisplayName 'WSL2 SSH' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 2222"
```

> This only needs to be run once to create the initial rule. The boot script in Phase 7 resets and recreates all port proxy rules on every restart because the WSL2 IP changes.

---

## Phase 5 — k3s and Helm Installation

> Run inside WSL2.

### `k3s_install.sh` — Install k3s, Helm, and Kubeconfig

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install k3s — no Traefik (we use NGINX), no built-in LB (we use MetalLB)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb --write-kubeconfig-mode 644" sh -

# Wait for node to be ready
until kubectl get node | grep -q " Ready"; do sleep 3; done
echo "k3s ready"

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install kubectl completion + aliases
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

# Copy kubeconfig so Mac can use it
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
# Replace 127.0.0.1 with the actual LAN IP so the Mac can reach the API
sed -i "s/127.0.0.1/$(hostname -I | awk '{print $1}')/g" ~/.kube/config
chmod 600 ~/.kube/config

echo "Kubeconfig at ~/.kube/config — copy to Mac"
```

Key flags passed to k3s:
- `--disable traefik` — NGINX Ingress is used instead
- `--disable servicelb` — MetalLB is used instead
- `--write-kubeconfig-mode 644` — makes the kubeconfig readable without sudo

The kubeconfig's server address is patched from `127.0.0.1` to the WSL2 LAN IP so it works when copied to a remote machine.

---

## Phase 6 — Terraform: Install Cluster Services

> Run inside WSL2 from the `terraform/` directory.

### Install Terraform (prerequisite)

```bash
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
```

---

### `terraform/variables.tf` — Configurable Variables

```hcl
variable "metallb_ip_range" {
  type    = list(string)
  default = ["10.55.55.150-10.55.55.170"]
}

variable "grafana_password" {
  type      = string
  default   = "changeme"
  sensitive = true
}
```

Adjust `metallb_ip_range` to a free block within your LAN subnet. The range must not overlap with DHCP-assigned addresses.

---

### `terraform/main.tf` — Cluster Services

Deploys all cluster services in dependency order via the Helm and Kubernetes Terraform providers.

```hcl
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# ── MetalLB ────────────────────────────────────────────────────────────────────
resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
}

resource "kubernetes_manifest" "metallb_pool" {
  depends_on = [helm_release.metallb]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata   = { name = "local-pool", namespace = "metallb-system" }
    spec       = { addresses = var.metallb_ip_range }
  }
  timeouts {
    create = "5m"
  }
}

resource "kubernetes_manifest" "metallb_l2advert" {
  depends_on = [kubernetes_manifest.metallb_pool]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata   = { name = "local-advert", namespace = "metallb-system" }
    spec       = {}
  }
  timeouts {
    create = "5m"
  }
}

# ── NGINX Ingress Controller ───────────────────────────────────────────────────
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
}

# ── cert-manager ──────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# ── kube-prometheus-stack (Prometheus + Grafana + Alertmanager) ───────────────
resource "helm_release" "monitoring" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  depends_on       = [helm_release.ingress_nginx]

  values = [<<-YAML
    grafana:
      ingress:
        enabled: true
        hosts: ["grafana.lab.local"]
      adminPassword: "${var.grafana_password}"
      sidecar:
        datasources:
          enabled: false
      additionalDataSources:
        - name: Loki
          type: loki
          url: http://loki:3100
          isDefault: false
    prometheus:
      ingress:
        enabled: true
        hosts: ["prometheus.lab.local"]
    alertmanager:
      ingress:
        enabled: true
        hosts: ["alertmanager.lab.local"]
    prometheusOperator:
      enabled: true
    prometheus-node-exporter:
      hostRootFsMount:
        enabled: false
  YAML
  ]
}

# ── Loki + Promtail (log aggregation) ─────────────────────────────────────────
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = "monitoring"
  create_namespace = false
  depends_on       = [helm_release.monitoring]

  set {
    name  = "grafana.enabled"
    value = "false"
  }

  set {
    name  = "promtail.enabled"
    value = "true"
  }
}
```

Deploy order enforced by `depends_on`:
1. MetalLB Helm release → IP pool manifest → L2 advertisement manifest
2. NGINX Ingress (independent of MetalLB in Terraform, but MetalLB must be running to assign it a LB IP)
3. cert-manager (independent)
4. kube-prometheus-stack (depends on NGINX ingress being up so ingress objects work)
5. Loki stack (depends on monitoring namespace existing from step 4)

#### Run Terraform

```bash
cd ~/wsl-kubernetes/terraform
terraform init
terraform apply
```

To override the Grafana password without editing the file:

```bash
terraform apply -var='grafana_password=mysecretpassword'
```

---

## Phase 7 — Boot Script (every Windows restart)

> Run in **PowerShell as Administrator** on the Windows host each time Windows restarts.

### `windows_launch_services.ps1` — Start WSL SSH + Refresh Port Proxy

```powershell
#Requires -RunAsAdministrator
<# 
.SYNOPSIS
    K8s Home Lab startup script.
    Run this every time the Windows machine boots before connecting from your Mac.
.NOTES
    Must be run as Administrator.
    Usage: .\windows_launch_services.ps1
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
Write-Host "  ssh <username>@<windows-lan-ip> -p 2222" -ForegroundColor White
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
```

`$MetalLBIP` must match the first IP in your MetalLB pool (set in `terraform/variables.tf`). The script resets **all** portproxy rules on every run and rebuilds them, so the WSL2 IP update is authoritative.

---

## Quick Reference — Execution Order

| # | Script | Where to run | When |
|---|--------|--------------|------|
| 1 | `install_ubuntu.ps1` | PowerShell (Admin) | Once — Windows initial setup |
| 2 | `enable_ssh.ps1` | PowerShell (Admin) | Once — optional Windows SSH |
| 3 | `config_ssh_daemon.sh` | WSL2 (Ubuntu) | Once — WSL SSH setup |
| 4 | `windows_port_forward.sh` | WSL2 (Ubuntu) | Once — initial port proxy |
| 5 | `k3s_install.sh` | WSL2 (Ubuntu) | Once — cluster install |
| 6 | `terraform init && apply` | WSL2 `terraform/` dir | Once — cluster services |
| 7 | `windows_launch_services.ps1` | PowerShell (Admin) | Every Windows boot |

---

## Useful Diagnostic Commands

```bash
# Check k3s node and pod status
kubectl get nodes
kubectl get pods -A

# Check MetalLB assigned IPs
kubectl get svc -A | grep LoadBalancer

# Check ingress rules
kubectl get ingress -A

# Restart k3s if needed
sudo systemctl restart k3s

# Check SSH daemon status inside WSL
sudo service ssh status

# View port proxy rules from Windows
netsh interface portproxy show all
```
