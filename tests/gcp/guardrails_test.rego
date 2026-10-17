package gca_test

import rego.v1

import data.gca

labels := {
	"gca-session": "s",
	"gca-expires": time.format([time.now_ns() + 3600000000000, "UTC", "20060102-1504"]),
	"managed-by": "governed-cloud-agent",
	"exposure": "public",
}

plan(rcs) := {"resource_changes": rcs}

rc(type, after) := {"address": sprintf("%s.x", [type]), "type": type, "change": {"actions": ["create"], "before": null, "after": after}}

svc(over) := object.union(
	{
		"location": "us-central1", "labels": labels,
		"template": [{"scaling": [{"min_instance_count": 0, "max_instance_count": 2}], "containers": [{
			"image": "us-central1-docker.pkg.dev/p/gca-runner/runner:v1",
			"resources": [{"limits": {"cpu": "1", "memory": "512Mi"}}],
		}]}],
	},
	over,
)

test_clean_service_passes if {
	count(gca.deny) == 0 with input as plan([rc("google_cloud_run_v2_service", svc({}))])
}

test_foreign_type_blocked if {
	some m in gca.deny with input as plan([rc("google_compute_instance", {})])
	contains(m, "not on the allow-list")
}

test_missing_label_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service", {"location": "us-central1", "labels": {"managed-by": "governed-cloud-agent"}, "template": [{"scaling": [{"min_instance_count": 0, "max_instance_count": 2}], "containers": [{"image": "us-central1-docker.pkg.dev/p/gca-runner/runner:v1", "resources": [{"limits": {"cpu": "1", "memory": "512Mi"}}]}]}]})])
	contains(m, "missing required label")
}

test_expiry_cap if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service", svc({"labels": object.union(labels, {"gca-expires": "20990101-0000"})}))])
	contains(m, "7 days")
}

test_region_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service", svc({"location": "asia-south1"}))])
	contains(m, "allow-list")
}

test_big_cpu_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service", svc({"template": [{"scaling": [{"min_instance_count": 0, "max_instance_count": 2}], "containers": [{"image": "us-central1-docker.pkg.dev/p/gca-runner/runner:v1", "resources": [{"limits": {"cpu": "8", "memory": "512Mi"}}]}]}]}))])
	contains(m, "cpu")
}

test_scaling_caps if {
	count(gca.deny) >= 2 with input as plan([rc("google_cloud_run_v2_service", svc({"template": [{"scaling": [{"min_instance_count": 5, "max_instance_count": 50}], "containers": [{"image": "us-central1-docker.pkg.dev/p/gca-runner/runner:v1", "resources": [{"limits": {"cpu": "1", "memory": "512Mi"}}]}]}]}))])
}

test_foreign_image_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service", svc({"template": [{"scaling": [{"min_instance_count": 0, "max_instance_count": 2}], "containers": [{"image": "docker.io/evil/miner", "resources": [{"limits": {"cpu": "1", "memory": "512Mi"}}]}]}]}))])
	contains(m, "runner image")
}

test_public_requires_declaration if {
	some m in gca.deny with input as plan([
		rc("google_cloud_run_v2_service", svc({"labels": object.union(labels, {"exposure": "private"})})),
		rc("google_cloud_run_v2_service_iam_member", {"member": "allUsers", "role": "roles/run.invoker"}),
	])
	contains(m, "exposure=public")
}

test_public_with_declaration_ok if {
	count(gca.deny) == 0 with input as plan([
		rc("google_cloud_run_v2_service", svc({})),
		rc("google_cloud_run_v2_service_iam_member", {"member": "allUsers", "role": "roles/run.invoker"}),
	])
}

test_invoker_foreign_member_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service_iam_member", {"member": "user:x@y.com", "role": "roles/run.invoker"})])
	contains(m, "allUsers")
}

test_service_owner_role_blocked if {
	some m in gca.deny with input as plan([rc("google_cloud_run_v2_service_iam_member", {"member": "allUsers", "role": "roles/run.admin"})])
	contains(m, "roles/run.invoker")
}

test_bucket_public_blocked if {
	some m in gca.deny with input as plan([rc("google_storage_bucket", {"name": "gca-app-x", "location": "us-central1", "labels": labels, "public_access_prevention": "inherited", "uniform_bucket_level_access": true})])
	contains(m, "public_access_prevention")
}

test_bucket_name if {
	some m in gca.deny with input as plan([rc("google_storage_bucket", {"name": "mine", "location": "us-central1", "labels": labels, "public_access_prevention": "enforced", "uniform_bucket_level_access": true})])
	contains(m, "gca-app-")
}

test_bucket_allusers_blocked if {
	some m in gca.deny with input as plan([rc("google_storage_bucket_iam_member", {"member": "allUsers", "role": "roles/storage.objectViewer"})])
	contains(m, "service account")
}

test_bucket_admin_role_blocked if {
	some m in gca.deny with input as plan([rc("google_storage_bucket_iam_member", {"member": "serviceAccount:a@b", "role": "roles/storage.admin"})])
	contains(m, "not allowed on buckets")
}

test_project_owner_blocked if {
	some m in gca.deny with input as plan([rc("google_project_iam_member", {"member": "serviceAccount:a@b", "role": "roles/owner", "condition": []})])
	contains(m, "not allowed")
}

test_datastore_unscoped_blocked if {
	some m in gca.deny with input as plan([rc("google_project_iam_member", {"member": "serviceAccount:a@b", "role": "roles/datastore.user", "condition": []})])
	contains(m, "restricted to one database")
}

test_datastore_scoped_ok if {
	count(gca.deny) == 0 with input as plan([rc("google_project_iam_member", {"member": "serviceAccount:a@b", "role": "roles/datastore.user", "condition": [{"expression": "resource.name == \"projects/p/databases/gca-x\""}]})])
}

test_delete_foreign_blocked if {
	r := {"address": "google_storage_bucket.y", "type": "google_storage_bucket", "change": {"actions": ["delete"], "before": {"labels": {}}, "after": null}}
	some m in gca.deny with input as plan([r])
	contains(m, "refusing to delete")
}
