variable "project_id" {
  description = "The GCP project id"
  type        = string
}

variable "region" {
  default     = "us-east1"
  description = "GCP region"
  type        = string
}

variable "environment" {
  default     = "dev"
  description = "env"
  type        = string
}

variable "labels" {
  default     = {}
  description = "Labels to attach"
  type        = object({})
}