resource "google_compute_network" "network" {
  provider                = google-beta
  project                 = var.project_id # Replace this with your project ID in quotes
  name                    = "psa-test"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc_subnetwork" {
  provider                 = google-beta
  project                  = google_compute_network.network.project
  name                     = "test-subnetwork"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = "us-east1"
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}

resource "google_compute_global_address" "default" {
  provider     = google-beta
  project      = google_compute_network.network.project
  name         = "global-psconnect-ip"
  address_type = "INTERNAL"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = google_compute_network.network.id
  address      = "10.3.0.5"
}

resource "google_compute_global_forwarding_rule" "default" {
  provider              = google-beta
  project               = google_compute_network.network.project
  name                  = "globalrule"
  target                = "all-apis"
  network               = google_compute_network.network.id
  ip_address            = google_compute_global_address.default.id
  load_balancing_scheme = ""
}

resource "google_compute_instance" "test_vm" {
  project      = var.project_id
  name         = "psa-test-vm"
  provider     = google-beta
  zone         = "us-east1-b"
  machine_type = "f1-micro"
  network_interface {
    network    = google_compute_network.network.id
    subnetwork = google_compute_subnetwork.vpc_subnetwork.id
  }
  boot_disk {
    initialize_params {
      image = "ubuntu-2004-focal-v20220905"
    }
  }
}

resource "google_compute_firewall" "fw-iap" {
  project       = var.project_id
  name          = "l7-ilb-fw-allow-iap-hc"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

resource "google_dns_managed_zone" "private-zone" {
  name        = "private-zone"
  project     = var.project_id
  dns_name    = "gcr.io."
  description = "google container registry"
  labels = {
    foo = "bar"
  }

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.network.id
    }
  }
}

resource "google_dns_record_set" "default" {
  managed_zone = google_dns_managed_zone.private-zone.name
  name         = "gcr.io."
  type         = "A"
  rrdatas      = [google_compute_global_address.default.address]
  ttl          = 86400
}