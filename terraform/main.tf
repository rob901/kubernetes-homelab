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

# MetalLB
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

# NGINX Ingress
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
}

# cert-manager
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

# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)

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


# Loki stack (log aggregation)
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
