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

variable "topic_name" {
  default     = "log_sink_topic"
  description = "The name of the Pub/Sub topic pointed to by the log sink"
  type        = string
}

variable "sink_name" {
  default     = "log_sink"
  description = "The name of the log sink which forwards log events to Pub/Sub"
  type        = string
}

variable "labels" {
  default     = {}
  description = "Labels to attach"
  type        = object({})
}