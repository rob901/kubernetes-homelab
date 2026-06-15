# ── NGINX Ingress Controller ───────────────────────────────────────────────────
# Ingress controllers handle HTTP/S routing into the cluster based on hostname
# and path rules defined in Ingress objects. When deployed, it creates a Service
# of type LoadBalancer — MetalLB assigns it an IP (10.55.55.150) which becomes
# the single entry point for all web traffic. k3s ships Traefik by default but
# it is disabled at install time; NGINX is used here for wider compatibility
# with community chart examples and annotations.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
}
