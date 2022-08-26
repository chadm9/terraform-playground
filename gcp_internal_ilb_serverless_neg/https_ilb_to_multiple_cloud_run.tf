/*
Terraform proof of concept for deploying an internal HTTPS load balancer (ilb)
with a severless network endpoint group (NEG) backend exposing a Cloud Run service.
The NEG employs the url mask in order to hit an unlimited number of Cloud Run services.
A specfic Cloud Run service can be hit by specificy the name of the Cloud Run service in
the host header of the HTTPS request.  The ilb itself employes a self-signed cert for
encryption, which is set to expire after 1 year. The components of this PoC are derived
from the following resources:

Attaching a Cloud Run serverless NEG to an internal HTTP/HTTPS load balancer
https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal-serverless#gcloud_1
Architecture diagram:
https://cloud.google.com/static/load-balancing/images/lb-serverless-simple-int-https.svg

Setting up an HTTP/HTTPS load balancer with a GCE MIG backend:
https://cloud.google.com/load-balancing/docs/l7-internal/int-https-lb-tf-examples
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
resource "google_compute_network" "default" {
  project                 = var.project_id
  name                    = "l7-ilb-network"
  provider                = google-beta
  auto_create_subnetworks = false
}

# Create a subnet for the 'required' (see below) VM instance
resource "google_compute_subnetwork" "default" {
  name          = "l7-ilb-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  project       = var.project_id
  network       = google_compute_network.default.name
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
    network    = google_compute_network.default.id
    subnetwork = google_compute_subnetwork.default.id
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
  network       = google_compute_network.default.id
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
  network     = google_compute_network.default.id
  priority    = "65535"
  direction   = "EGRESS"

  allow {
    protocol = "all"
  }
}

# Create a Cloud Run service
resource "google_cloud_run_service" "default" {
  name     = "hello"
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
  network       = google_compute_network.default.id
}

# Reserve a static internal ip address for the ilb
resource "google_compute_address" "default" {
  name          = "l7-ilb-reserved-ip"
  subnetwork    = google_compute_subnetwork.default.id
  address_type  = "INTERNAL"
  description   = "A reserved static internal ip for use by the Cloud Run ilb"
  region        = var.region
  project       = var.project_id
}

# Regional forwarding rule
resource "google_compute_forwarding_rule" "default" {
  name                  = "l7-ilb-forwarding-rule"
  region                = "us-east1"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  ip_address            = google_compute_address.default.id
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.default.id
  network               = google_compute_network.default.id
  subnetwork            = google_compute_subnetwork.default.id
  network_tier          = "PREMIUM"
}

# Self-signed regional SSL certificate for testing
resource "tls_private_key" "default" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "default" {
  private_key_pem = tls_private_key.default.private_key_pem

  # Certificate expires after a year.
  validity_period_hours = 8760

  /*
  Generate a new certificate if Terraform is run within a month
  of the certificate's expiration time.
  */
  early_renewal_hours = 730

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
  dns_names = ["example.com"]
}

resource "google_compute_region_ssl_certificate" "default" {
  name_prefix = "my-certificate-"
  private_key = tls_private_key.default.private_key_pem
  certificate = tls_self_signed_cert.default.cert_pem
  region      = "us-east1"
  lifecycle {
    create_before_destroy = true
  }
}

# Regional target HTTPS proxy
resource "google_compute_region_target_https_proxy" "default" {
  name             = "l7-ilb-target-https-proxy"
  region           = "us-east1"
  url_map          = google_compute_region_url_map.default.id
  ssl_certificates = [google_compute_region_ssl_certificate.default.self_link]
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
  /*
  The following code configures a URL mask to access multiple Cloud Run services.
  To hit a Cloud Run service, an HTTP request should be made to the internal load
  balancer ip passing a host header value which is the name of the service.  For
  example, if the load balancer ip 10.0.1.2, and the Cloud Run service is named
  'hello', the following curl command will reach the service:

  curl --header 'Host: hello' -k https://10.0.1.2

  (note the '-k' in the above is to stop curl from complaining about
  the self-signed cert)
  */
  cloud_run {
    url_mask = "<service>"
  }
}