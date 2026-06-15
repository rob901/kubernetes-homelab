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
