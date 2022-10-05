resource "google_compute_network" "network" {
  provider                = google-beta
  project                 = var.project_id # Replace this with your project ID in quotes
  name                    = "psa-test"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetwork" {
  provider                 = google-beta
  project                  = google_compute_network.network.project
  name                     = "test-subnetwork"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = "us-east1"
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}

resource "google_compute_instance" "test_vm" {
  project      = var.project_id
  name         = "test-vm"
  provider     = google-beta
  zone         = "us-east1-b"
  machine_type = "f1-micro"
  network_interface {
    network    = google_compute_network.network.id
    subnetwork = google_compute_subnetwork.subnetwork.id

    access_config {
      // Ephemeral public IP
    }
  }
  metadata_startup_script = templatefile("${path.module}/startup.sh", {})

  boot_disk {
    initialize_params {
      image = "ubuntu-2004-focal-v20220905"
    }
  }
  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    scopes = ["cloud-platform"]
  }
  allow_stopping_for_update = true
}

resource "google_compute_firewall" "fw-iap" {
  project       = var.project_id
  name          = "allow-iap-ingress"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "project_firewall_deny_egress" {

  project     = var.project_id
  name        = "allow-all-egress"
  description = "Deny egress from VPC by default"
  network     = google_compute_network.network.id
  priority    = "65535"
  direction   = "EGRESS"


  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }
}


resource "google_logging_metric" "logging_metric" {
  project = var.project_id
  name   = "test-log-based-metric"
  filter = "log_name=(projects/neon-nexus-297211/logs/syslog) AND textPayload:\"hello\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      key         = "text_payload"
      value_type  = "STRING"
      description = "the textPayload property value of the log event"
    }
  }
  label_extractors = {
    "text_payload" = "EXTRACT(textPayload)"
  }
}

resource "google_monitoring_alert_policy" "alert_policy" {
  project = var.project_id
  notification_channels = [google_monitoring_notification_channel.email-me.name]
  display_name = "Test Alert Policy"
  combiner     = "OR"
  conditions {
    display_name = "log statement appeared" // This will show up in the email
    condition_threshold {
      aggregations {
        alignment_period = "60s"
        per_series_aligner = "ALIGN_DELTA"
      }
      filter     = "metric.type=\"logging.googleapis.com/user/test-log-based-metric\" AND resource.type=\"gce_instance\""
      duration   = "0s"
      comparison = "COMPARISON_GT"
      threshold_value = 0
    }
  }
  documentation {
    mime_type = "text/markdown"
    content = "This is from terraform"
  }
}

resource "google_monitoring_notification_channel" "email-me" {
  display_name = "Email Me"
  type = "email"
  labels = {
    email_address = "chadm_@yahoo.com"
  }
}