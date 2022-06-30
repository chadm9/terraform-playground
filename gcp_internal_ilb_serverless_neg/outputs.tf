output "ilb_ip_address" {
  description = "The internal IP assigned to the regional forwarding rule (ilb)."
  value       = google_compute_address.l7-ilb-reserved-ip.address
}