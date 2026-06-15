# ── MetalLB ───────────────────────────────────────────────────────────────────
# k3s disables its built-in load balancer (servicelb) because it conflicts with
# MetalLB. MetalLB watches for Services of type LoadBalancer and assigns them a
# real IP from the pool below, making them reachable on the LAN.
# wait = true holds Terraform here until all MetalLB pods are Running before
# moving on — required because the next two resources apply MetalLB CRDs that
# won't exist until the pods have registered them with the API server.
resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
}

# Defines the pool of IPs MetalLB can hand out to LoadBalancer Services.
# The range must be free addresses within your LAN subnet — they must not
# overlap with your router's DHCP range. Configured via var.metallb_ip_range
# in variables.tf. depends_on is explicit here because Terraform can't infer
# the dependency — there's no HCL reference to the helm_release above.
# The 5m timeout gives the CRD time to fully register in the API server after
# the Helm release completes; without it, apply can fail immediately.
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

# Tells MetalLB to advertise the IP pool using Layer 2 (ARP).
# In L2 mode, MetalLB responds to ARP requests for the pool IPs, making them
# appear as if they belong to the Windows/WSL host on your LAN. This is the
# simplest mode and works on any flat home network without BGP router support.
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
