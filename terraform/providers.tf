# ── Terraform configuration ───────────────────────────────────────────────────
# Declares which providers this configuration needs and pins their versions.
# The helm provider installs Helm charts; the kubernetes provider applies raw
# Kubernetes manifests (used for MetalLB CRDs that have no Helm equivalent).
# ~> 2.13 means ">=2.13, <3.0" — allows minor/patch updates but blocks major
# breaking changes when you run `terraform init -upgrade`.
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

# ── Providers ─────────────────────────────────────────────────────────────────
# Both providers read ~/.kube/config to authenticate against the cluster.
# This file is written by k3s_install.sh and has the WSL2 LAN IP patched in
# so it works from inside WSL. If the IP changes after a reboot, re-run the
# kubeconfig section of k3s_install.sh before running terraform.
provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}
