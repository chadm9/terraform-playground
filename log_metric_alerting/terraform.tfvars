project_id                 = "neon-nexus-297211"
region                     = "us-east1"
environment                = "dev"
notification_email_address = "chadm_@yahoo.com"
alignment_period           = "120s"
alert_threshold            = 0
policies = {
  hello-in-syslog = {
    event_name          = "hello-in-syslog"
    // This must be a GCP Cloud Logging which isolates the log event to trigger an alert on
    cloud_logging_query = "log_name=(projects/neon-nexus-297211/logs/syslog) AND textPayload:\"hello\""
    // This is the type of resource producing the log event.  Here we have a GCE instance for demo purposes but it could have been 'cloud_run_revision' if, for example, Cloud Run produced the alert
    resource_type       = "gce_instance"
    documentation       = "This alert fires in response to the text \"hello\" appearing in a syslog GCP log entry in the neon-nexus-297211 project."
  },
  goodbye-in-syslog = {
    event_name          = "goodbye-in-syslog"
    cloud_logging_query = "log_name=(projects/neon-nexus-297211/logs/syslog) AND textPayload:\"goodbye\""
    resource_type       = "gce_instance"
    documentation       = "This alert fires in response to the text \"goodbye\" appearing in a syslog GCP log entry in the neon-nexus-297211 project."
  },
}