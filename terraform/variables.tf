variable "metallb_ip_range" {
  type    = list(string)
  default = ["10.55.55.150-10.55.55.170"]
}

variable "grafana_password" {
  type      = string
  default   = "changeme"
  sensitive = true
}
