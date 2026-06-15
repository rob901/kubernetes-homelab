# WSL Kubernetes Home Lab

A lightweight Kubernetes cluster running inside WSL2 on a Windows machine, accessible from any SSH client (Windows or Mac) on the same network.

## Architecture Overview

```
Mac / Windows SSH Client
        │
        │  ssh <windows-ip> -p 2222
        ▼
Windows Host (e.g. 10.55.55.30)
  ├── OpenSSH Server  (port 22  — Windows native, optional)
  ├── Port Proxy      (port 2222 → WSL2:2222)
  ├── Port Proxy      (port 80   → MetalLB:80)
  └── Port Proxy      (port 443  → MetalLB:443)
        │
        ▼
WSL2 / Ubuntu 22.04
  ├── SSH daemon (port 2222)
  └── k3s cluster
        ├── MetalLB          (IP pool: 10.55.55.150–170)
        ├── NGINX Ingress    (LoadBalancer IP: 10.55.55.150)
        ├── cert-manager
        ├── Prometheus       → prometheus.lab.local
        ├── Grafana          → grafana.lab.local
        ├── Alertmanager     → alertmanager.lab.local
        └── Loki + Promtail
```

**Stack:**
- k3s (lightweight Kubernetes, no Traefik, no built-in LB)
- MetalLB (Layer 2 load balancer)
- NGINX Ingress Controller
- cert-manager
- kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
- Loki + Promtail (log aggregation)
- Terraform (cluster services deployment)
- Helm (chart management)

---

## Prerequisites

- Windows 10 (build 19041+) or Windows 11
- Administrator access on the Windows machine
- The Windows machine must be on a LAN subnet that can accommodate the MetalLB IP range (`10.55.55.150–170` by default — adjust in `terraform/variables.tf` if needed)
- PowerShell 5+ (built into Windows)

---

## Phase 1 — Windows Initial Setup

> Run these steps once on the Windows machine. All PowerShell commands require an **Administrator** terminal.

### 1.1 Install WSL2 and Ubuntu 22.04

Open PowerShell as Administrator and run:

```powershell
wsl --install -d Ubuntu-22.04
```

Restart Windows when prompted. After reboot, Ubuntu will finish installing and ask you to create a UNIX username and password — remember these, you will need them to SSH in.

### 1.2 Enable Windows OpenSSH Server (optional — for direct Windows SSH access)

This installs the native Windows SSH server on port 22. Skip if you only need WSL SSH access.

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

---

## Phase 2 — WSL2 SSH Configuration

> Run these steps once inside the WSL2 Ubuntu shell. Open WSL by typing `wsl` in a Windows terminal.

### 2.1 Install and configure the SSH daemon

Inside WSL (Ubuntu), run:

```bash
sudo apt-get update && sudo apt-get install -y openssh-server

sudo tee /etc/ssh/sshd_config.d/wsl.conf > /dev/null <<'EOF'
Port 2222
PasswordAuthentication yes
EOF

sudo service ssh start
```

This configures the WSL SSH daemon to listen on **port 2222** (avoids conflict with Windows SSH on port 22) and allows password authentication.

---

## Phase 3 — Windows Port Forwarding (one-time firewall setup)

> Still inside WSL, this script calls back into PowerShell to create the port proxy and firewall rule.

```bash
WSL_IP=$(hostname -I | awk '{print $1}')
powershell.exe -Command "netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$WSL_IP"
powershell.exe -Command "New-NetFirewallRule -Name wsl-ssh -DisplayName 'WSL2 SSH' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 2222"
```

> **Note:** WSL2 gets a new IP every boot. Phase 3 only creates the initial rule. The `windows_launch_services.ps1` boot script (Phase 7) handles refreshing this automatically on every restart.

---

## Phase 4 — Verify SSH Connectivity

From your Mac (or any machine on the same network), find your Windows machine's LAN IP (`ipconfig` on Windows), then:

```bash
ssh <your-username>@<windows-lan-ip> -p 2222
```

From another Windows machine:

```powershell
ssh <your-username>@<windows-lan-ip> -p 2222
```

If using a Mac, you can add an entry to `~/.ssh/config` for convenience:

```
Host k8s-lab
    HostName <windows-lan-ip>
    Port 2222
    User <your-wsl-username>
```

Then connect with: `ssh k8s-lab`

---

## Phase 5 — Install k3s and Helm

> Run from inside WSL (via SSH or direct WSL terminal).

```bash
bash k3s_install.sh
```

This script:
1. Installs k3s with Traefik and the built-in service load balancer disabled (MetalLB and NGINX replace them)
2. Waits for the node to reach `Ready` state
3. Installs Helm
4. Adds `kubectl` shell completion and the `k` alias to `~/.bashrc`
5. Copies and patches the kubeconfig to `~/.kube/config` with the WSL LAN IP so it can be used remotely

Verify the cluster is up:

```bash
kubectl get nodes
kubectl get pods -A
```

---

## Phase 6 — Deploy Cluster Services with Terraform

> Run from inside WSL, from the `terraform/` directory.

### 6.1 Install Terraform

```bash
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
```

### 6.2 Initialize and apply

```bash
cd ~/wsl-kubernetes/terraform
terraform init
terraform apply
```

Confirm the plan with `yes`. This deploys the following services via Helm in dependency order:

**MetalLB** (`metallb-system`)
k3s has no built-in load balancer that works on bare metal. MetalLB fills that gap — it watches for Kubernetes `Service` objects of type `LoadBalancer` and assigns them a real IP from a configured pool (`10.55.55.150–170` by default). Without it, LoadBalancer services would stay in `<pending>` forever.

**NGINX Ingress Controller** (`ingress-nginx`)
Routes external HTTP/S traffic into the cluster based on hostname and path rules. It receives a LoadBalancer IP from MetalLB (`10.55.55.150`) and acts as the single entry point for all web-facing services. k3s ships with Traefik by default, but it is disabled here in favour of NGINX for broader ecosystem compatibility.

**cert-manager** (`cert-manager`)
Automates TLS certificate provisioning and renewal inside the cluster. It watches `Ingress` and `Certificate` objects and can issue certificates from Let’s Encrypt or a self-signed CA, removing the need for manual certificate management.

**kube-prometheus-stack** (`monitoring`)
Deploys Prometheus (metrics scraping and alerting), Grafana (dashboards), and Alertmanager (alert routing and silencing) as a pre-wired bundle. Prometheus scrapes metrics from cluster nodes and workloads automatically. Ingress rules are created for all three services so they are reachable by hostname from your local network.

**Loki + Promtail** (`monitoring`)
Loki is a log aggregation system designed to work alongside Prometheus. Promtail runs as a DaemonSet on each node, tails container logs, and ships them to Loki. Grafana is pre-configured with a Loki datasource so you can query logs alongside metrics in the same UI without a separate logging stack.

### 6.3 Configure variables (optional)

Edit `terraform/variables.tf` to customise:

```hcl
variable "metallb_ip_range" {
  default = ["10.55.55.150-10.55.55.170"]   # adjust to your LAN subnet
}

variable "grafana_password" {
  default = "changeme"   # change this
}
```

Or pass them at apply time:

```bash
terraform apply -var='grafana_password=mysecretpassword'
```

---

## Phase 7 — Boot Script (run on every Windows restart)

Every time Windows restarts, WSL2 gets a new IP and the SSH daemon stops. Run the boot script as **Administrator** in PowerShell before connecting:

```powershell
.\windows_launch_services.ps1
```

This script:
1. Starts the WSL2 SSH daemon
2. Resets all port proxy rules and recreates them with the current WSL2 IP
3. Ensures firewall rules exist for ports 2222, 80, and 443
4. Tests that SSH is reachable on port 2222

**Tip:** Schedule this as a Task Scheduler job triggered on login (as Administrator) so it runs automatically on each boot:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NonInteractive -WindowStyle Hidden -File C:\path\to\windows_launch_services.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
               -RunLevel Highest
Register-ScheduledTask -TaskName "K8sLabStartup" -Action $action `
  -Trigger $trigger -Principal $principal
```

---

## Accessing the Cluster Services

The MetalLB IP `10.55.55.150` is the NGINX ingress entry point. Add these entries to your **Mac or Windows `hosts` file** to reach services by hostname.

**Mac:** `/etc/hosts`  
**Windows:** `C:\Windows\System32\drivers\etc\hosts`

```
10.55.55.150  grafana.lab.local
10.55.55.150  prometheus.lab.local
10.55.55.150  alertmanager.lab.local
```

Then open in a browser:

| URL | Credentials |
|---|---|
| http://grafana.lab.local | admin / `grafana_password` variable |
| http://prometheus.lab.local | — |
| http://alertmanager.lab.local | — |

### Copy kubeconfig to Mac (optional)

To run `kubectl` locally on your Mac:

```bash
# On your Mac
mkdir -p ~/.kube
scp -P 2222 <your-username>@<windows-lan-ip>:~/.kube/config ~/.kube/config
```

Then verify:

```bash
kubectl get nodes
```

---

## Repository Structure

```
wsl-kubernetes/
├── install_ubuntu.ps1          # Phase 1 — install WSL2 + Ubuntu on Windows
├── enable_ssh.ps1              # Phase 1 — enable Windows native SSH server
├── config_ssh_daemon.sh        # Phase 2 — configure SSH daemon inside WSL2
├── windows_port_forward.sh     # Phase 3 — one-time port proxy + firewall setup
├── k3s_install.sh              # Phase 5 — install k3s + Helm
├── windows_launch_services.ps1 # Phase 7 — run on every Windows boot
└── terraform/
    ├── main.tf                 # MetalLB, NGINX, cert-manager, Prometheus, Loki
    ├── variables.tf            # MetalLB IP range, Grafana password
    └── .terraform.lock.hcl    # Provider version lock file
```

---

## Troubleshooting

**SSH connection refused on port 2222**  
Run `windows_launch_services.ps1` as Administrator — the WSL IP may have changed since last boot.

**MetalLB IPs not reachable from Mac**  
The MetalLB range must be within the same `/24` subnet as your Windows host. Update `terraform/variables.tf` and re-apply if your LAN uses a different subnet.

**kubectl: connection refused**  
The kubeconfig references the WSL2 IP. Re-run `k3s_install.sh` (the kubeconfig section at the end) after any Windows restart to refresh it.

**`terraform apply` fails on MetalLB CRDs**  
MetalLB CRDs need a moment to register after the Helm release. If apply fails with a CRD timeout, wait 30 seconds and run `terraform apply` again — the `depends_on` chain and 5-minute timeouts handle transient delays.
