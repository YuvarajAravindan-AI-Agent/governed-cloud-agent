# One-time GCP bootstrap, applied by a human (founder@). Two projects:
#   control   - chat app, state bucket, Vertex AI, the agent's own identities
#   workloads - the only project the agent can create anything in
terraform {
  required_version = ">= 1.5"
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

variable "org_id" {
  type    = string
  default = "414303410035"
}
variable "billing_account" {
  type    = string
  default = "012A9E-2D5529-FF781A"
}
variable "quota_project" {
  type    = string
  default = "project-287c53a0-e18a-40e8-824"
}
variable "region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  user_project_override = true
  billing_project       = var.quota_project
}

resource "random_id" "sfx" {
  byte_length = 2
}

locals {
  control   = "gca-control-${random_id.sfx.hex}"
  workloads = "gca-workloads-${random_id.sfx.hex}"
  control_apis = [
    "run.googleapis.com", "artifactregistry.googleapis.com", "aiplatform.googleapis.com", "iam.googleapis.com",
    "iamcredentials.googleapis.com", "storage.googleapis.com", "cloudscheduler.googleapis.com",
    "cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "compute.googleapis.com", "logging.googleapis.com",
  ]
  workloads_apis = [
    "run.googleapis.com", "artifactregistry.googleapis.com", "firestore.googleapis.com", "iam.googleapis.com",
    "iamcredentials.googleapis.com", "storage.googleapis.com", "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_project" "control" {
  name                = "GCA control"
  project_id          = local.control
  org_id              = var.org_id
  billing_account     = var.billing_account
  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project" "workloads" {
  name                = "GCA workloads"
  project_id          = local.workloads
  org_id              = var.org_id
  billing_account     = var.billing_account
  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project_service" "control" {
  for_each           = toset(local.control_apis)
  project            = google_project.control.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "workloads" {
  for_each           = toset(local.workloads_apis)
  project            = google_project.workloads.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---- control project: state, registry, identities ----
resource "google_storage_bucket" "state" {
  name                        = "gca-state-${google_project.control.project_id}"
  project                     = google_project.control.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = true
  }
  depends_on = [google_project_service.control]
}

resource "google_artifact_registry_repository" "chat" {
  project       = google_project.control.project_id
  location      = var.region
  repository_id = "gca"
  format        = "DOCKER"
  depends_on    = [google_project_service.control]
}

resource "google_service_account" "executor" {
  project      = google_project.control.project_id
  account_id   = "gca-executor"
  display_name = "Terraform executor (workloads project only)"
  depends_on   = [google_project_service.control]
}

resource "google_service_account" "agent" {
  project      = google_project.control.project_id
  account_id   = "gca-agent-app"
  display_name = "Chat app runtime"
  depends_on   = [google_project_service.control]
}

resource "google_project_iam_member" "agent_vertex" {
  project = google_project.control.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent.email}"
}

resource "google_storage_bucket_iam_member" "agent_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.agent.email}"
}

# The chat app may mint short-lived tokens for the executor, nobody else can.
resource "google_service_account_iam_member" "agent_impersonates_executor" {
  service_account_id = google_service_account.executor.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.agent.email}"
}

# ---- workloads project: what the executor may do ----
locals {
  executor_roles = [
    "roles/run.admin",
    "roles/storage.admin",
    "roles/datastore.owner",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/browser",
  ]
}

resource "google_project_iam_member" "executor" {
  for_each = toset(local.executor_roles)
  project  = google_project.workloads.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.executor.email}"
}

# May grant ONE role only (datastore.user), nothing else, so it cannot escalate itself.
resource "google_project_iam_member" "executor_delegated" {
  project = google_project.workloads.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.executor.email}"
  condition {
    title       = "grant-datastore-user-only"
    description = "Executor may only grant roles/datastore.user"
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/datastore.user'])"
  }
}

resource "google_artifact_registry_repository" "runner" {
  project       = google_project.workloads.project_id
  location      = var.region
  repository_id = "gca-runner"
  format        = "DOCKER"
  depends_on    = [google_project_service.workloads]
}

# Cloud Run checks that the deployer can read the image: read-only, runner repo only.
resource "google_artifact_registry_repository_iam_member" "executor_reads_runner" {
  project    = google_project.workloads.project_id
  location   = var.region
  repository = google_artifact_registry_repository.runner.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.executor.email}"
}

# ---- Sandbox for testing generated code (control project) ----
# A Cloud Run job that runs as a service account with NO roles, attached to a VPC with no internet route.
variable "sandbox_image" {
  type    = string
  default = ""
}

resource "google_compute_network" "sandbox" {
  project                 = google_project.control.project_id
  name                    = "gca-sandbox-net"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.control]
}

resource "google_compute_subnetwork" "sandbox" {
  project                  = google_project.control.project_id
  name                     = "gca-sandbox-subnet"
  region                   = var.region
  network                  = google_compute_network.sandbox.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = false
}

# No Cloud NAT exists, so there is no internet route anyway; this rule makes the intent explicit.
resource "google_compute_firewall" "sandbox_deny_egress" {
  project            = google_project.control.project_id
  name               = "gca-sandbox-deny-all-egress"
  network            = google_compute_network.sandbox.id
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
}

resource "google_service_account" "sandbox" {
  project      = google_project.control.project_id
  account_id   = "gca-sandbox"
  display_name = "Sandbox runtime (no roles)"
  depends_on   = [google_project_service.control]
}

resource "google_cloud_run_v2_job" "sandbox" {
  count               = var.sandbox_image == "" ? 0 : 1
  project             = google_project.control.project_id
  name                = "gca-sandbox"
  location            = var.region
  deletion_protection = false
  template {
    task_count = 1
    template {
      service_account = google_service_account.sandbox.email
      max_retries     = 0
      timeout         = "300s"
      containers {
        image = var.sandbox_image
        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = google_compute_network.sandbox.id
          subnetwork = google_compute_subnetwork.sandbox.id
        }
      }
    }
  }
  depends_on = [google_compute_firewall.sandbox_deny_egress]
}

# The chat app may start executions of this one job (with an env override) and read their status and logs.
resource "google_cloud_run_v2_job_iam_member" "agent_runs_sandbox" {
  count    = var.sandbox_image == "" ? 0 : 1
  project  = google_project.control.project_id
  location = var.region
  name     = google_cloud_run_v2_job.sandbox[0].name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = "serviceAccount:${google_service_account.agent.email}"
}

resource "google_project_iam_member" "agent_run_viewer" {
  project = google_project.control.project_id
  role    = "roles/run.viewer"
  member  = "serviceAccount:${google_service_account.agent.email}"
}

resource "google_project_iam_member" "agent_logs_viewer" {
  project = google_project.control.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.agent.email}"
}

output "control_project" {
  value = google_project.control.project_id
}
output "workloads_project" {
  value = google_project.workloads.project_id
}
output "state_bucket" {
  value = google_storage_bucket.state.name
}
output "executor_sa" {
  value = google_service_account.executor.email
}
output "agent_sa" {
  value = google_service_account.agent.email
}
output "chat_repo" {
  value = "${var.region}-docker.pkg.dev/${google_project.control.project_id}/gca"
}
output "runner_repo" {
  value = "${var.region}-docker.pkg.dev/${google_project.workloads.project_id}/gca-runner"
}
