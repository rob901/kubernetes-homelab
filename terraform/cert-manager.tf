# ── cert-manager ──────────────────────────────────────────────────────────────
# Watches Ingress and Certificate objects and automatically provisions and
# renews TLS certificates. Without this, you would need to manually create
# and rotate certificates for any HTTPS service. installCRDs = true bundles
# the cert-manager CRD installation into the Helm chart rather than requiring
# a separate kubectl apply step before install.
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
