package gca

import rego.v1

# Input: output of `terraform show -json plan.tfplan`.
# Result: data.gca.deny, a set of human-readable violation strings.

allowed_types := {
	"google_cloud_run_v2_service", "google_cloud_run_v2_service_iam_member",
	"google_service_account",
	"google_storage_bucket", "google_storage_bucket_object", "google_storage_bucket_iam_member",
	"google_firestore_database", "google_project_iam_member",
	"archive_file", "random_id", "random_pet", "null_resource",
}

allowed_regions := {"us-central1", "us-east1"}

# Resource types that support labels and must carry the session/expiry labels.
labelled_types := {"google_cloud_run_v2_service", "google_storage_bucket"}

changes contains rc if {
	some rc in input.resource_changes
	some a in rc.change.actions
	a != "no-op"
	a != "read"
}

# 1. Only allow-listed resource types.
deny contains msg if {
	some rc in changes
	not rc.type in allowed_types
	msg := sprintf("%s: resource type %s is not on the allow-list", [rc.address, rc.type])
}

# 2. Labels so the reaper and audits can find everything.
deny contains msg if {
	some rc in changes
	rc.type in labelled_types
	labels := object.get(rc.change.after, "labels", {})
	some k in ["gca-session", "gca-expires", "managed-by"]
	not labels[k]
	msg := sprintf("%s: missing required label %s", [rc.address, k])
}

# 3. Nothing may be scheduled to live longer than 7 days (label format YYYYMMDD-hhmm, UTC).
deny contains msg if {
	some rc in changes
	rc.type in labelled_types
	exp := object.get(rc.change.after, "labels", {})["gca-expires"]
	time.parse_ns("20060102-1504", exp) > (time.now_ns() + (((7 * 24) * 3600) * 1000000000)) + (600 * 1000000000)
	msg := sprintf("%s: gca-expires %s is more than 7 days away", [rc.address, exp])
}

# 4. Region allow-list.
deny contains msg if {
	some rc in changes
	rc.type in {"google_cloud_run_v2_service", "google_storage_bucket"}
	loc := lower(rc.change.after.location)
	not loc in allowed_regions
	msg := sprintf("%s: location %s is not in the allow-list", [rc.address, loc])
}

# 5. Cloud Run sizing caps.
deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	c := rc.change.after.template[0].containers[_]
	lim := c.resources[0].limits
	not lim.cpu in {"1", "1000m", "0.5", "500m"}
	msg := sprintf("%s: cpu limit %v exceeds the cap of 1", [rc.address, lim.cpu])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	c := rc.change.after.template[0].containers[_]
	lim := c.resources[0].limits
	not lim.memory in {"128Mi", "256Mi", "512Mi"}
	msg := sprintf("%s: memory limit %v exceeds the cap of 512Mi", [rc.address, lim.memory])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	sc := rc.change.after.template[0].scaling[0]
	sc.max_instance_count > 3
	msg := sprintf("%s: max_instance_count %d exceeds the cap of 3", [rc.address, sc.max_instance_count])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	sc := rc.change.after.template[0].scaling[0]
	sc.min_instance_count > 1
	msg := sprintf("%s: min_instance_count %d exceeds the cap of 1", [rc.address, sc.min_instance_count])
}

# 6. Containers must come from the platform runner repository.
deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	img := rc.change.after.template[0].containers[_].image
	not regex.match(`^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/gca-runner/runner:`, img)
	msg := sprintf("%s: containers must use the platform runner image (gca-runner), got %s", [rc.address, img])
}

# 7. A public service (allUsers invoker) must be declared with label exposure=public; no other members.
deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service_iam_member"
	rc.change.after.member != "allUsers"
	msg := sprintf("%s: Cloud Run invoker may only be granted to allUsers (public) by this platform", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service_iam_member"
	rc.change.after.role != "roles/run.invoker"
	msg := sprintf("%s: only roles/run.invoker may be granted on a service", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service_iam_member"
	not public_declared
	msg := sprintf("%s: public access requires label exposure=public on the service", [rc.address])
}

public_declared if {
	some rc in changes
	rc.type == "google_cloud_run_v2_service"
	rc.change.after.labels.exposure == "public"
}

# 8. Buckets: private, uniform access, named gca-app-*.
deny contains msg if {
	some rc in changes
	rc.type == "google_storage_bucket"
	not startswith(rc.change.after.name, "gca-app-")
	msg := sprintf("%s: bucket name must start with gca-app-", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_storage_bucket"
	rc.change.after.public_access_prevention != "enforced"
	msg := sprintf("%s: bucket must set public_access_prevention = enforced", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_storage_bucket"
	rc.change.after.uniform_bucket_level_access != true
	msg := sprintf("%s: bucket must use uniform bucket-level access", [rc.address])
}

# 9. Bucket IAM: only the app's own service account, only read/use roles.
deny contains msg if {
	some rc in changes
	rc.type == "google_storage_bucket_iam_member"
	not startswith(rc.change.after.member, "serviceAccount:")
	msg := sprintf("%s: bucket access may only be granted to a service account", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_storage_bucket_iam_member"
	not rc.change.after.role in {"roles/storage.objectViewer", "roles/storage.objectUser"}
	msg := sprintf("%s: role %s is not allowed on buckets", [rc.address, rc.change.after.role])
}

# 10. Project-level IAM is only allowed for datastore.user, scoped to one named database by a condition.
deny contains msg if {
	some rc in changes
	rc.type == "google_project_iam_member"
	rc.change.after.role != "roles/datastore.user"
	msg := sprintf("%s: project role %s is not allowed", [rc.address, rc.change.after.role])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_project_iam_member"
	not startswith(rc.change.after.member, "serviceAccount:")
	msg := sprintf("%s: project roles may only go to service accounts", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "google_project_iam_member"
	not scoped_to_database(rc)
	msg := sprintf("%s: datastore.user must be restricted to one database with an IAM condition", [rc.address])
}

scoped_to_database(rc) if {
	cond := rc.change.after.condition[0]
	contains(cond.expression, "resource.name == ")
	contains(cond.expression, "/databases/gca-")
}

# 11. Firestore databases are named gca-*.
deny contains msg if {
	some rc in changes
	rc.type == "google_firestore_database"
	not startswith(rc.change.after.name, "gca-")
	msg := sprintf("%s: database name must start with gca-", [rc.address])
}

# 12. Service accounts are named gca-*.
deny contains msg if {
	some rc in changes
	rc.type == "google_service_account"
	not startswith(rc.change.after.account_id, "gca-")
	msg := sprintf("%s: service account id must start with gca-", [rc.address])
}

# 13. Never delete what this platform did not create.
deny contains msg if {
	some rc in changes
	"delete" in rc.change.actions
	rc.type in labelled_types
	object.get(object.get(rc.change.before, "labels", {}), "managed-by", "") != "governed-cloud-agent"
	msg := sprintf("%s: refusing to delete a resource not managed by governed-cloud-agent", [rc.address])
}
