/*
Terraform proof of concept for deploying an internal http load balancer (ilb)
to two severless network endpoint groups (NEG) backend exposing two Cloud Run services.
The components of this PoC are derived from the following tutorial:
https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal-serverless#gcloud_1

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

# Create a subnet for the 'required' (see below) VM instance
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

/*
--OPTIONAL--
Create a firewall rule allowing all egress from the vpc.  This ensures
that vm-test can curl the ilb for testing purposes, but may be overly broad
for real use cases depending on security requirements.
*/
resource "google_compute_firewall" "project_firewall_allow_egress" {

  project     = var.project_id
  name        = "allow-all-egress"
  description = "Allow egress from VPC by default"
  network     = google_compute_network.ilb_network.id
  priority    = "65535"
  direction   = "EGRESS"

  allow {
    protocol = "all"
  }
}

# Create the first Cloud Run service
resource "google_cloud_run_service" "service1" {
  name     = "service1"
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

# Create the second Cloud Run service
resource "google_cloud_run_service" "service2" {
  name     = "service2"
  location = var.region
  project  = var.project_id

  template {
    spec {
      containers {
        image = "gcr.io/cloud-marketplace/google/nginx1:1.15"
      }
    }
  }
}

/*
Allow anyone (i.e. allUsers) to invoke the first Cloud Run service
GET request to its HTTP(s) endpoint
*/
resource "google_cloud_run_service_iam_member" "member1" {
  location = google_cloud_run_service.service1.location
  project  = google_cloud_run_service.service1.project
  service  = google_cloud_run_service.service1.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

/*
Allow anyone (i.e. allUsers) to invoke the second Cloud Run service
GET request to its HTTP(s) endpoint
*/
resource "google_cloud_run_service_iam_member" "member2" {
  location = google_cloud_run_service.service2.location
  project  = google_cloud_run_service.service2.project
  service  = google_cloud_run_service.service2.name
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
Create the required proxy only subnet for load balancer source ip
addresses as seen by backends. Only one is needed per region, and
one proxy only subnet is capable of supporting multiple envoy based lbs.
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

# Reserve a static internal ip address for the ilb
resource "google_compute_address" "l7-ilb-reserved-ip" {
  name          = "l7-ilb-reserved-ip"
  subnetwork    = google_compute_subnetwork.ilb_subnet.id
  address_type  = "INTERNAL"
  description   = "A reserved static internal ip for use by the Cloud Run ilb"
  region        = var.region
  project       = var.project_id
}

# Create the ilb forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  project               = var.project_id
  name                  = "l7-ilb-forwarding-rule"
  region                = "us-east1"
  ip_address            = google_compute_address.l7-ilb-reserved-ip.address
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

/*
Create the ilb URL map.  All default_service fields are required. To reach the cloud
run services from the ilb, an http request must be sent to the ilb ip address with path
'/service1' for service 1, and '/service2' for service two.  Additionally, the host
header option must be passed in the http request ('test.com' in the example below).

As an example, from inside the vcp, executing this curl command

curl --header 'Host: test.com' 10.0.1.2/service2/test

will make a GET request to cloud run service 2 with path '/service2/test'
and a host header field of 'test.com' (note in the above example 10.0.1.2 is the
ip of the ilb).
*/
resource "google_compute_region_url_map" "default" {
  project         = var.project_id
  name            = "l7-ilb-regional-url-map"
  provider        = google-beta
  region          = "us-east1"
  default_service = google_compute_region_backend_service.service1.id

  host_rule {
    hosts        = ["test.com"]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_region_backend_service.service1.id

    path_rule {
      paths   = ["/service1/*"]
      service = google_compute_region_backend_service.service1.id
    }

    path_rule {
      paths   = ["/service2/*"]
      service = google_compute_region_backend_service.service2.id
    }
  }
}

# Create the backend service for cloud run service 1
resource "google_compute_region_backend_service" "service1" {
  project               = var.project_id
  name                  = "l7-ilb-backend-service1"
  provider              = google-beta
  region                = "us-east1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 30
  backend {
    group           = google_compute_region_network_endpoint_group.cloudrun_neg_1.id
    balancing_mode  = ""
  }
}

# Create the Cloud Run Network Endpoint Group (NEG) for cloud run service 1.
resource "google_compute_region_network_endpoint_group" "cloudrun_neg_1" {
  project               = var.project_id
  provider              = google-beta
  name                  = "cloud-run-neg1"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_service.service1.name
  }
}

# Create the backend service for cloud run service 2
resource "google_compute_region_backend_service" "service2" {
  project               = var.project_id
  name                  = "l7-ilb-backend-service2"
  provider              = google-beta
  region                = "us-east1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 30
  backend {
    group           = google_compute_region_network_endpoint_group.cloudrun_neg_2.id
    balancing_mode  = ""
  }
}

# Create the Cloud Run Network Endpoint Group (NEG) for cloud run service 2.
resource "google_compute_region_network_endpoint_group" "cloudrun_neg_2" {
  project               = var.project_id
  provider              = google-beta
  name                  = "cloud-run-neg2"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_service.service2.name
  }
}