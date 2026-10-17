terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

variable "app_name" {
  type = string
}
variable "session_id" {
  type = string
}
variable "expires" {
  type = string
}
variable "project_id" {
  type = string
}
variable "region" {
  type = string
}
variable "public" {
  type    = bool
  default = true
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  name   = "gca-${var.app_name}-${substr(var.session_id, 0, 6)}"
  bucket = "gca-app-${var.app_name}-${substr(var.session_id, 0, 6)}-${var.project_id}"
  labels = {
    "gca-session" = var.session_id
    "gca-expires" = formatdate("YYYYMMDD-hhmm", var.expires)
    "managed-by"  = "governed-cloud-agent"
    "exposure"    = var.public ? "public" : "private"
  }
  runner_image = "${var.region}-docker.pkg.dev/${var.project_id}/gca-runner/runner:v1"
}


data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/app"
  output_path = "${path.module}/app.zip"
}

resource "google_service_account" "app" {
  account_id   = substr(local.name, 0, 30)
  display_name = "gca app ${local.name}"
}

resource "google_storage_bucket" "bundle" {
  name                        = local.bucket
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels
}

resource "google_storage_bucket_object" "bundle" {
  name   = "bundle.zip"
  bucket = google_storage_bucket.bundle.name
  source = data.archive_file.code.output_path
}

resource "google_storage_bucket_iam_member" "read" {
  bucket = google_storage_bucket.bundle.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app.email}"
}


resource "google_cloud_run_v2_service" "app" {
  name                = local.name
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"
  labels              = local.labels
  template {
    service_account = google_service_account.app.email
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
    containers {
      image = local.runner_image
      ports {
        container_port = 8080
      }
      env {
        name  = "BUNDLE_BUCKET"
        value = google_storage_bucket.bundle.name
      }
      env {
        name  = "BUNDLE_KEY"
        value = "bundle.zip"
      }
      env {
        name  = "BUNDLE_HASH"
        value = data.archive_file.code.output_md5
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }
  depends_on = [google_storage_bucket_object.bundle, google_storage_bucket_iam_member.read]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.public ? 1 : 0
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "url" {
  value = google_cloud_run_v2_service.app.uri
}
output "function" {
  value = google_cloud_run_v2_service.app.name
}

