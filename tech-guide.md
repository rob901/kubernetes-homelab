# Operations Guide — Installation & Setup

Run these steps in order. Scripts are in the repo root unless otherwise noted.

---

## 1. Install WSL2 + Ubuntu — Windows (PowerShell as Admin)

`install_ubuntu.ps1` — installs Ubuntu 22.04 on WSL2.

```powershell
.\install_ubuntu.ps1
```

Restart Windows when prompted. After reboot, Ubuntu will launch and ask for a UNIX username and password — save these.

---

## 2. Enable Windows SSH Server — Windows (PowerShell as Admin, optional)

`enable_ssh.ps1` — installs the Windows OpenSSH server on port 22. Skip if you only need WSL SSH access.

```powershell
.\enable_ssh.ps1
```

---

## 3. Configure WSL2 SSH Daemon — inside WSL

`config_ssh_daemon.sh` — installs openssh-server, sets it to listen on port 2222, enables password auth, and starts the service.

```bash
bash config_ssh_daemon.sh
```

---

## 4. Set Up Windows Port Forwarding — inside WSL

`windows_port_forward.sh` — reads the current WSL2 IP and calls back into PowerShell to create a port proxy rule (Windows:2222 → WSL:2222) and the matching firewall rule.

```bash
bash windows_port_forward.sh
```

---

## 5. Install k3s and Helm — inside WSL

`k3s_install.sh` — installs k3s (Traefik and built-in LB disabled), waits for node ready, installs Helm, adds kubectl aliases, and writes a patched kubeconfig to `~/.kube/config`.

```bash
bash k3s_install.sh
```

Verify the cluster is up:

```bash
kubectl get nodes
kubectl get pods -A
```

---

## 6. Deploy Cluster Services — inside WSL, from `terraform/`

Installs MetalLB, NGINX Ingress, cert-manager, Prometheus/Grafana/Alertmanager, and Loki via Terraform + Helm.

Install Terraform first if not already installed:

```bash
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
```

Then apply:

```bash
cd ~/wsl-kubernetes/terraform
terraform init
terraform apply
```

To set a custom Grafana password:

```bash
terraform apply -var='grafana_password=mysecretpassword'
```

---

## 7. Every Boot — Windows (PowerShell as Admin)

`windows_launch_services.ps1` — starts the WSL SSH daemon, resets and recreates all port proxy rules with the current WSL2 IP, checks firewall rules, and verifies SSH is reachable. Must be run after every Windows restart before connecting.

```powershell
.\windows_launch_services.ps1
```

To run this automatically on login, register it as a scheduled task:

```powershell
$action    = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NonInteractive -WindowStyle Hidden -File C:\path\to\windows_launch_services.ps1"
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
Register-ScheduledTask -TaskName "K8sLabStartup" -Action $action -Trigger $trigger -Principal $principal
```

---

## 8. Add Hosts Entries (Mac or Windows client)

Add to `/etc/hosts` (Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
10.55.55.150  grafana.lab.local
10.55.55.150  prometheus.lab.local
10.55.55.150  alertmanager.lab.local
```

---

## Summary

| Step | Script / Command | Run on |
|------|-----------------|--------|
| 1 | `install_ubuntu.ps1` | Windows (Admin PS) |
| 2 | `enable_ssh.ps1` | Windows (Admin PS) — optional |
| 3 | `config_ssh_daemon.sh` | WSL2 |
| 4 | `windows_port_forward.sh` | WSL2 |
| 5 | `k3s_install.sh` | WSL2 |
| 6 | `terraform init && apply` | WSL2 — `terraform/` dir |
| 7 | `windows_launch_services.ps1` | Windows (Admin PS) — every boot |
| 8 | Edit hosts file | Mac / Windows client |
