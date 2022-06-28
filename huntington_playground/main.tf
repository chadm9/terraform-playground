/*
Terraform proof of concept for deploying an internal http load balancer (ilb)
with a severless network endpoint group (NEG) backend exposing a Cloud Run service.
The components of this PoC are derived from the following tutorial:
https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal-serverless#gcloud_1

See here for an architecture diagram:
https://cloud.google.com/static/load-balancing/images/lb-serverless-simple-int-https.svg
*/



#############################
# Supporting Infrastructure #
############################3

/*
This includes infrastructure that is required to support an internal http
load balancer with a serverless Cloud Run NEG, but which is not a part of the ILB
or NEG, and therefore may well be defined elsewhere.  Make sure the Supporting
Infrastructure is in place before attempting to create the Core Infrastructure.
*/

# Creat a VPC network to house the internal load balancer (ilb)
resource "google_compute_network" "ilb_network" {
  project                 = var.project_id
  name                    = "l7-ilb-network"
  provider                = google-beta
  auto_create_subnetworks = false
}

# Create a subnet for the 'required' (see below) GCE instance
resource "google_compute_subnetwork" "ilb_subnet" {
  name          = "l7-ilb-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  project       = var.project_id
  network       = google_compute_network.ilb_network.id
}

/*
According to GCP:
"There must be at least one VM in the VPC network in which you intend
to set up a regional load balancer with a serverless backend."
https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal-serverless#gcloud_1
*/
# Create the required VM instance
resource "google_compute_instance" "vm-test" {
  project      = var.project_id
  name         = "l7-ilb-test-vm"
  provider     = google-beta
  zone         = "us-east1-b"
  machine_type = "e2-small"
  network_interface {
    network    = google_compute_network.ilb_network.id
    subnetwork = google_compute_subnetwork.ilb_subnet.id
  }
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }
}

/*
--OPTIONAL--
Create a firewall rule to whitelist access from IAP so the required GCE
instance (see above), which has no external ip, is accessible via ssh
(assuming the user trying to ssh has the proper roles assigned, e.g., editor).
*/
resource "google_compute_firewall" "fw-iap" {
  project       = var.project_id
  name          = "l7-ilb-fw-allow-iap-hc"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.ilb_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# Create a Cloud Run service
resource "google_cloud_run_service" "default" {
  name     = "hello-service"
  location = var.region
  project  = var.project_id

  template {
    spec {
      containers {
        image = "gcr.io/cloudrun/hello"
      }
    }
  }
}

/*
Allow anyone (i.e. allUsers) to invoke a Cloud Run container by issuing a
GET request to its HTTP(s) endpoint
*/
resource "google_cloud_run_service_iam_member" "member" {
  location = google_cloud_run_service.default.location
  project  = google_cloud_run_service.default.project
  service  = google_cloud_run_service.default.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}



#############################
#    Core Infrastructure    #
#############################

/*
Infrastructure which directly defines the internal HTTP ILB and its serverless
Cloud Run NEG.  If creating, ensure the Supporting Infrastructure is already in place
and properly referenced.
*/

/*
Create the required proxy only subnet for load balancer
source ip addresses as seen by backends. Only one is needed per
region and is capable of supporting multiple envoy based lbs.
https://cloud.google.com/load-balancing/docs/proxy-only-subnets
*/
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "l7-ilb-proxy-only-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  project       = var.project_id
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.ilb_network.id
}

# Create the ilb forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  project               = var.project_id
  name                  = "l7-ilb-forwarding-rule"
  provider              = google-beta
  region                = "us-east1"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.ilb_network.id
  subnetwork            = google_compute_subnetwork.ilb_subnet.id
  network_tier          = "PREMIUM"
}

# Create the ilb HTTP target proxy
resource "google_compute_region_target_http_proxy" "default" {
  project  = var.project_id
  name     = "l7-ilb-target-http-proxy"
  provider = google-beta
  region   = "us-east1"
  url_map  = google_compute_region_url_map.default.id
}

# Create the ilb URL map
resource "google_compute_region_url_map" "default" {
  project         = var.project_id
  name            = "l7-ilb-regional-url-map"
  provider        = google-beta
  region          = "us-east1"
  default_service = google_compute_region_backend_service.default.id
}

# Create the backend service
resource "google_compute_region_backend_service" "default" {
  project               = var.project_id
  name                  = "l7-ilb-backend-service"
  provider              = google-beta
  region                = "us-east1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 30
  backend {
    group           = google_compute_region_network_endpoint_group.cloudrun_neg.id
    balancing_mode  = ""
  }
}

# Create the Cloud Run Network Endpoint Group (NEG).
resource "google_compute_region_network_endpoint_group" "cloudrun_neg" {
  project               = var.project_id
  provider              = google-beta
  name                  = "cloud-run-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_service.default.name
  }
}