/*
This script is a proof of concept for creating alerts from log-based metrics in GCP.
The alerts herein will fire when a specified log statement appears in GCP Cloud Logging
one or more times within a specified (alignment_period) timeframe. The notification
channel for the alert is set to email.

In this POC, additional infrastructure which is not related to log-based
metric alerts is also provisioned for the purposes of demoing/testing.  This includes
a test VM with the Stackdriver logging agent installed and configured to write it's
Linux system logs (syslog) to GCP Cloud Logging, and the networking infrastructure
to support and ssh into said VM.
*/



/*
--OPTIONAL TEST INFRASTRUCTURE USED FOR DEMO/TESTING ONLY--
Create a vpc network to deploy the test VM into
*/
resource "google_compute_network" "network" {
  // provider                = google-beta
  project                 = var.project_id
  name                    = "test-vpc"
  auto_create_subnetworks = false
}

/*
--OPTIONAL TEST INFRASTRUCTURE USED FOR DEMO/TESTING ONLY--
Create a subnet to deploy the test VM into
*/
resource "google_compute_subnetwork" "subnetwork" {
  // provider                 = google-beta
  project                  = google_compute_network.network.project
  name                     = "test-subnetwork"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = "us-east1"
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}

/*
--OPTIONAL TEST INFRASTRUCTURE USED FOR DEMO/TESTING ONLY--
Create a test VM and pass a startup script which installs
the Stackdriver logging agent, and configures Linux syslogs
to be forwarded to GCP Cloud Logging.  When SSH'd into this
VM, executing the command:

logger "<some-log-statement>"

will write the contents of <some-log-statement> to Cloud Logging
under a log named 'syslog'
*/
resource "google_compute_instance" "test_vm" {
  project      = var.project_id
  name         = "test-vm"
 // provider     = google-beta
  zone         = "us-east1-b"
  machine_type = "f1-micro"
  network_interface {
    network    = google_compute_network.network.id
    subnetwork = google_compute_subnetwork.subnetwork.id

    // Creates an ephemeral public IP for the VM to provide a route to the internet
    access_config {
    }
  }
  // This startup script installs and conifigures the GCP logging agent
  metadata_startup_script = templatefile("${path.module}/startup.sh", {})

  boot_disk {
    initialize_params {
      image = "ubuntu-2004-focal-v20220905"
    }
  }
  service_account {
    scopes = ["cloud-platform"]
  }
  allow_stopping_for_update = true
}

/*
--OPTIONAL TEST INFRASTRUCTURE USED FOR DEMO/TESTING ONLY--
Allow ssh access into the VM through GCP's Identity Aware Proxy service
*/
resource "google_compute_firewall" "fw_iap" {
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

/*
--OPTIONAL TEST INFRASTRUCTURE USED FOR DEMO/TESTING ONLY--
Allow egress to the internet to enable downloading of required
package information
*/
resource "google_compute_firewall" "project_firewall_allow_egress" {

  project     = var.project_id
  name        = "allow-all-egress"
  description = "Allow egress from VPC by default"
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

/*
--EVERYTHING BELOW THIS LINE DEALS DIRECTLY WITH LOG BASED METRIC ALERTING--
*/

// Create a notification channel for the alert based on email
resource "google_monitoring_notification_channel" "default" {
  display_name = "Email Notification Channel"
  type = "email"
  labels = {
    email_address = var.notification_email_address
  }
}

// Create the log based metric
resource "google_logging_metric" "log_based_metric" {
  for_each = var.policies

  project = var.project_id
  name   = "${each.value.event_name}-metric"
  filter = each.value.cloud_logging_query
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      // Note for JSON-based GCP logs we should look instead at jsonPayload
      key         = "text_payload"
      value_type  = "STRING"
      description = "the log event statement"
    }
  }
  label_extractors = {
    /*
    This extracts the log text into a label so it can be easily included in an email.
    Note for JSON-based GCP logs we should look instead at 'jsonPayload'
    */
    "text_payload" = "EXTRACT(textPayload)"
  }
}

// Create the alert policy
resource "google_monitoring_alert_policy" "alert_policy" {
  for_each = var.policies
  // Make certain the metrics to alert on have been created
  depends_on = [google_logging_metric.log_based_metric]

  project               = var.project_id
  notification_channels = [google_monitoring_notification_channel.default.name]
  display_name          = "${each.value.event_name}-alert"
  combiner              = "OR"
  conditions {
    display_name = "${each.value.event_name}-alert"
    condition_threshold {
      aggregations {
        alignment_period = var.alignment_period
        per_series_aligner = "ALIGN_DELTA"
      }
      filter     = "metric.type=\"logging.googleapis.com/user/${each.value.event_name}-metric\" AND resource.type=\"${each.value.resource_type}\""
      duration   = "0s"
      comparison = "COMPARISON_GT"
      threshold_value = var.alert_threshold
    }
  }
  documentation {
    mime_type = "text/markdown"
    content = each.value.documentation
  }
}