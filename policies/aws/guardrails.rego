package gca

import rego.v1

# Input: output of `terraform show -json plan.tfplan`.
# Result: data.gca.deny — a set of human-readable violation strings.

allowed_types := {
	"aws_lambda_function", "aws_lambda_function_url", "aws_lambda_permission",
	"aws_iam_role", "aws_iam_role_policy_attachment", "aws_iam_role_policy",
	"aws_cloudwatch_log_group",
	"aws_dynamodb_table",
	"aws_s3_bucket", "aws_s3_bucket_public_access_block", "aws_s3_bucket_server_side_encryption_configuration",
	"aws_s3_bucket_versioning", "aws_s3_bucket_lifecycle_configuration",
	"aws_sqs_queue", "aws_sns_topic",
	"aws_cloudwatch_event_rule", "aws_cloudwatch_event_target",
	"aws_apigatewayv2_api", "aws_apigatewayv2_stage", "aws_apigatewayv2_integration", "aws_apigatewayv2_route",
	"aws_s3_object", "aws_s3_bucket_policy",
	"aws_ecs_cluster", "aws_ecs_task_definition", "aws_ecs_service",
	"aws_lb", "aws_lb_target_group", "aws_lb_listener", "aws_security_group",
	"aws_cloudfront_distribution", "aws_cloudfront_origin_access_control",
	"random_id", "random_pet", "archive_file", "null_resource",
}

allowed_regions := {"us-east-1", "us-west-2"}
taggable_types := {"aws_lambda_function", "aws_iam_role", "aws_dynamodb_table", "aws_s3_bucket", "aws_sqs_queue", "aws_sns_topic", "aws_cloudwatch_log_group", "aws_ecs_cluster", "aws_ecs_service", "aws_ecs_task_definition", "aws_lb", "aws_lb_target_group", "aws_security_group", "aws_cloudfront_distribution"}

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

# 2. Every taggable resource carries session + TTL tags (so the reaper can find it).
deny contains msg if {
	some rc in changes
	rc.type in taggable_types
	tags := object.get(rc.change.after, "tags_all", object.get(rc.change.after, "tags", {}))
	some k in ["gca-session", "gca-expires", "managed-by"]
	not tags[k]
	msg := sprintf("%s: missing required tag %s", [rc.address, k])
}

# 3. IAM: roles must carry the permissions boundary.
deny contains msg if {
	some rc in changes
	rc.type == "aws_iam_role"
	object.get(rc.change.after, "permissions_boundary", null) == null
	msg := sprintf("%s: IAM role must set permissions_boundary", [rc.address])
}

# 4. IAM: no wildcard actions or resources in inline policies.
deny contains msg if {
	some rc in changes
	rc.type in {"aws_iam_role_policy", "aws_iam_role"}
	doc := policy_docs(rc)[_]
	stmt := as_array(json.unmarshal(doc).Statement)[_]
	stmt.Effect == "Allow"
	wildcard(stmt)
	msg := sprintf("%s: IAM policy statement uses a wildcard Action or Resource", [rc.address])
}

policy_docs(rc) := [rc.change.after.policy] if rc.type == "aws_iam_role_policy"
policy_docs(rc) := [p.policy | some p in object.get(rc.change.after, "inline_policy", [])] if rc.type == "aws_iam_role"

wildcard(stmt) if {
	some a in as_array(stmt.Action)
	a == "*"
}

wildcard(stmt) if {
	some a in as_array(stmt.Action)
	endswith(a, ":*")
}

wildcard(stmt) if {
	some r in as_array(stmt.Resource)
	r == "*"
}

as_array(x) := x if is_array(x)
as_array(x) := [x] if not is_array(x)

# 5. IAM: managed policy attachments only from a short list.
allowed_managed := {
	"arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
	"arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_iam_role_policy_attachment"
	not rc.change.after.policy_arn in allowed_managed
	msg := sprintf("%s: managed policy %s is not allowed", [rc.address, rc.change.after.policy_arn])
}

# 6. If the plan creates any S3 bucket it must also create a fully-on public access block.
deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket"
	not pab_fully_on
	msg := sprintf("%s: S3 bucket needs an aws_s3_bucket_public_access_block with all four settings true", [rc.address])
}

pab_fully_on if {
	some rc in changes
	rc.type == "aws_s3_bucket_public_access_block"
	rc.change.after.block_public_acls == true
	rc.change.after.block_public_policy == true
	rc.change.after.restrict_public_buckets == true
	rc.change.after.ignore_public_acls == true
}

# 7. Lambda sizing caps keep the bill predictable.
deny contains msg if {
	some rc in changes
	rc.type == "aws_lambda_function"
	rc.change.after.memory_size > 1024
	msg := sprintf("%s: memory_size %d exceeds the 1024 MB cap", [rc.address, rc.change.after.memory_size])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_lambda_function"
	rc.change.after.timeout > 30
	msg := sprintf("%s: timeout %d exceeds the 30 s cap", [rc.address, rc.change.after.timeout])
}

# 8. A public Function URL (auth NONE) must be explicitly declared on the function.
deny contains msg if {
	some rc in changes
	rc.type == "aws_lambda_function_url"
	rc.change.after.authorization_type == "NONE"
	not public_declared
	msg := sprintf("%s: public URL (authorization_type NONE) requires tag exposure=public on the function", [rc.address])
}

public_declared if {
	some rc in changes
	rc.type == "aws_lambda_function"
	rc.change.after.tags.exposure == "public"
}

# 9. Destroying anything outside this session's own resources is never allowed.
deny contains msg if {
	some rc in changes
	"delete" in rc.change.actions
	tags := object.get(rc.change.before, "tags", {})
	object.get(tags, "managed-by", "") != "governed-cloud-agent"
	msg := sprintf("%s: refusing to delete a resource not managed by governed-cloud-agent", [rc.address])
}

# 10. Region allow-list.
deny contains msg if {
	r := input.configuration.provider_config.aws.expressions.region.constant_value
	not r in allowed_regions
	msg := sprintf("provider region %s is not in the allow-list", [r])
}

# 11. Nothing may be scheduled to live longer than 7 days.
deny contains msg if {
	some rc in changes
	rc.type in taggable_types
	tags := object.get(rc.change.after, "tags_all", object.get(rc.change.after, "tags", {}))
	exp := tags["gca-expires"]
	time.parse_rfc3339_ns(exp) > (time.now_ns() + (((7 * 24) * 3600) * 1000000000)) + (600 * 1000000000)
	msg := sprintf("%s: gca-expires %s is more than 7 days away", [rc.address, exp])
}

# 12. Inline IAM policies must be fully known at plan time; an unknown policy cannot be inspected, so it is refused.
deny contains msg if {
	some rc in changes
	rc.type == "aws_iam_role_policy"
	object.get(object.get(rc.change, "after_unknown", {}), "policy", false) == true
	msg := sprintf("%s: IAM policy is not known at plan time (build ARNs from variables, not resource attributes)", [rc.address])
}

# 13. Fargate sizing and count caps.
deny contains msg if {
	some rc in changes
	rc.type == "aws_ecs_task_definition"
	to_number(rc.change.after.cpu) > 512
	msg := sprintf("%s: task cpu %v exceeds the 512 cap", [rc.address, rc.change.after.cpu])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_ecs_task_definition"
	to_number(rc.change.after.memory) > 1024
	msg := sprintf("%s: task memory %v exceeds the 1024 MB cap", [rc.address, rc.change.after.memory])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_ecs_service"
	rc.change.after.desired_count > 2
	msg := sprintf("%s: desired_count %d exceeds the cap of 2", [rc.address, rc.change.after.desired_count])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_ecs_task_definition"
	not regex.match(`^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/gca-runner:`, runner_image(rc))
	msg := sprintf("%s: containers must use the platform runner image (gca-runner)", [rc.address])
}

runner_image(rc) := img if {
	defs := json.unmarshal(rc.change.after.container_definitions)
	img := defs[0].image
}

# 14. Security groups: only 80/443 may be open to the world.
deny contains msg if {
	some rc in changes
	rc.type == "aws_security_group"
	some ing in rc.change.after.ingress
	"0.0.0.0/0" in ing.cidr_blocks
	not ing.from_port in {80, 443}
	msg := sprintf("%s: port %d is open to 0.0.0.0/0 (only 80 and 443 are allowed)", [rc.address, ing.from_port])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_security_group"
	some ing in rc.change.after.ingress
	"0.0.0.0/0" in ing.cidr_blocks
	ing.from_port != ing.to_port
	msg := sprintf("%s: world-open ingress must be a single port", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_security_group"
	some ing in rc.change.after.ingress
	"::/0" in object.get(ing, "ipv6_cidr_blocks", [])
	msg := sprintf("%s: IPv6 world-open ingress is not allowed", [rc.address])
}

# 15. Load balancers: HTTP/HTTPS listeners only, on 80/443.
deny contains msg if {
	some rc in changes
	rc.type == "aws_lb_listener"
	not rc.change.after.port in {80, 443}
	msg := sprintf("%s: listener port %d is not allowed", [rc.address, rc.change.after.port])
}

# 16. CloudFront: cheapest price class only.
deny contains msg if {
	some rc in changes
	rc.type == "aws_cloudfront_distribution"
	rc.change.after.price_class != "PriceClass_100"
	msg := sprintf("%s: CloudFront price_class must be PriceClass_100", [rc.address])
}

# 17. S3 bucket policies may only grant access to the CloudFront service principal.
deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket_policy"
	stmt := as_array(json.unmarshal(rc.change.after.policy).Statement)[_]
	stmt.Effect == "Allow"
	stmt.Principal != {"Service": "cloudfront.amazonaws.com"}
	msg := sprintf("%s: bucket policy may only allow the cloudfront.amazonaws.com principal", [rc.address])
}

# 18. App buckets must be named gca-app-* (that is all the boundary and executor can reach).
deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket"
	not startswith(rc.change.after.bucket, "gca-app-")
	msg := sprintf("%s: bucket name must start with gca-app-", [rc.address])
}
