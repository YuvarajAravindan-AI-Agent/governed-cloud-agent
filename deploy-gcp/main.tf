# Hosts the GCP chat app: Cloud Run (scales to zero) + hourly Cloud Scheduler reaper.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

variable "control_project" {
  type = string
}
variable "workloads_project" {
  type = string
}
variable "state_bucket" {
  type = string
}
variable "executor_sa" {
  type = string
}
variable "agent_sa" {
  type = string
}
variable "image" {
  type    = string
  default = ""
}
variable "moyai_relay_url" {
  type    = string
  default = "https://moyai.ai-agentic-enterprises.com/gca-relay"
}
variable "moyai_relay_token" {
  type      = string
  default   = ""
  sensitive = true
}
variable "region" {
  type    = string
  default = "us-central1"
}
variable "quota_project" {
  type    = string
  default = "project-287c53a0-e18a-40e8-824"
}

provider "google" {
  project               = var.control_project
  region                = var.region
  user_project_override = true
  billing_project       = var.quota_project
}

resource "random_password" "access" {
  length  = 32
  special = false
}

resource "google_cloud_run_v2_service" "app" {
  count               = var.image == "" ? 0 : 1
  name                = "gca-agent-app"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"
  template {
    service_account = var.agent_sa
    timeout         = "3600s"
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
    max_instance_request_concurrency = 4
    containers {
      image = var.image
      ports {
        container_port = 8080
      }
      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
      }
      env {
        name  = "GCA_ACCESS_KEY"
        value = random_password.access.result
      }
      env {
        name  = "GCA_STATE_BUCKET"
        value = var.state_bucket
      }
      env {
        name  = "GCA_GCP_PROJECT"
        value = var.workloads_project
      }
      env {
        name  = "GCA_GCP_CONTROL_PROJECT"
        value = var.control_project
      }
      env {
        name  = "GCA_GCP_EXECUTOR_SA"
        value = var.executor_sa
      }
      env {
        name  = "GCA_GCP_REGION"
        value = var.region
      }
      env {
        name  = "GCA_MOYAI_RELAY_URL"
        value = var.moyai_relay_url
      }
      env {
        name  = "GCA_MOYAI_RELAY_TOKEN"
        value = var.moyai_relay_token
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.image == "" ? 0 : 1
  name     = google_cloud_run_v2_service.app[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_scheduler_job" "reaper" {
  count     = var.image == "" ? 0 : 1
  name      = "gca-reaper-hourly"
  region    = var.region
  schedule  = "0 * * * *"
  time_zone = "UTC"
  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.app[0].uri}/events"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode(jsonencode({ gca_reaper_token = random_password.access.result }))
  }
  attempt_deadline = "900s"
}

output "chat_url" {
  value = var.image == "" ? "" : google_cloud_run_v2_service.app[0].uri
}
output "access_key" {
  value     = random_password.access.result
  sensitive = true
}
