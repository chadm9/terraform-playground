resource "google_vpc_access_connector" "connector" {
  project       = var.project_id
  name          = "vpc-con"
  min_instances = 2
  max_instances = 5
  subnet {
    name = google_compute_subnetwork.custom_sn.name
  }
  machine_type = "e2-micro"
}

resource "google_compute_subnetwork" "custom_sn" {
  name          = "vpc-con-sn"
  ip_cidr_range = "10.2.0.0/28"
  region        = var.region
  network       = google_compute_network.custom_vpc.id
}

resource "google_compute_network" "custom_vpc" {
  project                 = var.project_id
  name                    = "custom-vpc"
  auto_create_subnetworks = false
}