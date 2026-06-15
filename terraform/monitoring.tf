# ── kube-prometheus-stack ─────────────────────────────────────────────────────
# Installs Prometheus, Grafana, and Alertmanager as a pre-wired bundle.
# Prometheus scrapes metrics from nodes and workloads on a schedule;
# Alertmanager routes firing alerts to notification channels;
# Grafana provides the dashboard UI for both metrics and (via Loki) logs.
# depends_on ingress_nginx because the ingress objects below need the controller
# to exist before they can receive traffic.
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
        hosts: ["grafana.lab.local"]       # add this to your local hosts file
      adminPassword: "${var.grafana_password}"
      sidecar:
        datasources:
          # The sidecar auto-discovers datasources from ConfigMaps in the cluster.
          # Disabled here because we wire Loki in manually below via
          # additionalDataSources, avoiding a duplicate/conflicting entry.
          enabled: false
      additionalDataSources:
        # Pre-wire Loki as a datasource so Grafana can query logs immediately
        # after both stacks are deployed, without any manual UI configuration.
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
      # WSL2 does not expose the host root filesystem at /host/root the way a
      # real Linux node does. Enabling this causes the node-exporter DaemonSet
      # to fail on WSL2, so it is disabled.
      hostRootFsMount:
        enabled: false
  YAML
  ]
}

# ── Loki + Promtail ───────────────────────────────────────────────────────────
# Loki stores and indexes container logs; Promtail is the agent that collects
# them. Promtail runs as a DaemonSet on every node, tails all container log
# files, and forwards them to Loki. Grafana (deployed above) queries Loki for
# the Explore / logs view.
# grafana.enabled = false: the loki-stack chart bundles its own Grafana, but
#   we're already running one from kube-prometheus-stack — disable the duplicate.
# promtail.enabled = true: explicitly on (it's the default, but stated clearly
#   since it's the only component from this chart we actually want).
# create_namespace = false: reuses the monitoring namespace created above.
# depends_on monitoring: ensures the namespace and Grafana datasource config
#   exist before Loki tries to register itself.
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
