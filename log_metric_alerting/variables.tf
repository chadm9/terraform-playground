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

variable "notification_email_address" {
  description = "The email address to send alert notifications to"
  type        = string
}

variable "policies" {
  description = "A list of policies which define the events to create metrics and alerts on"
  type        = map(object({
    event_name            = string // The name of the event to create a metric and alert on
    cloud_logging_query   = string // The GCP Cloud Logging query which identifies the event
    resource_type         = string // The type of GCP resource which creates the log entry, e.g., 'gce_instance' for a GCP compute engine VM.  See this page for all possible values: https://cloud.google.com/monitoring/api/resources
    documentation         = string // Documentation to include in the event notification
  }))
}

variable "alignment_period" {
  description = "The time intervals in which GCP will check if the number of alerts exceeds the alert threshold. Values should be multiples of 60s"
  type        = string
  default     = "300s"
}

variable "alert_threshold" {
  description = "The number of times a log statement must appear within an alignment period to trigger an alert, minus one."
  type        = number
  default     = 0
}