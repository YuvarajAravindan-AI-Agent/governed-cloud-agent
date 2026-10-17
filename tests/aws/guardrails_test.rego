package gca_test

import rego.v1

import data.gca

tags := {"gca-session": "s", "gca-expires": time.format([time.now_ns() + 3600000000000, "UTC", "2006-01-02T15:04:05Z"]), "managed-by": "governed-cloud-agent"}

plan(rcs) := {"resource_changes": rcs, "configuration": {"provider_config": {"aws": {"expressions": {"region": {"constant_value": "us-east-1"}}}}}}

rc(type, after) := {"address": sprintf("%s.x", [type]), "type": type, "change": {"actions": ["create"], "before": null, "after": after}}

test_clean_lambda_passes if {
	count(gca.deny) == 0 with input as plan([rc("aws_lambda_function", {"tags": tags, "memory_size": 256, "timeout": 10})])
}

test_untagged_blocked if {
	count(gca.deny) > 0 with input as plan([rc("aws_lambda_function", {"tags": {}, "memory_size": 256, "timeout": 10})])
}

test_ec2_not_allowed if {
	some m in gca.deny with input as plan([rc("aws_instance", {"tags": tags})])
	contains(m, "not on the allow-list")
}

test_role_without_boundary_blocked if {
	some m in gca.deny with input as plan([rc("aws_iam_role", {"tags": tags, "permissions_boundary": null})])
	contains(m, "permissions_boundary")
}

test_wildcard_policy_blocked if {
	pol := json.marshal({"Statement": [{"Effect": "Allow", "Action": "s3:*", "Resource": "arn:aws:s3:::x"}]})
	some m in gca.deny with input as plan([rc("aws_iam_role_policy", {"policy": pol})])
	contains(m, "wildcard")
}

test_admin_attachment_blocked if {
	some m in gca.deny with input as plan([rc("aws_iam_role_policy_attachment", {"policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess"})])
	contains(m, "not allowed")
}

test_public_bucket_without_pab_blocked if {
	some m in gca.deny with input as plan([rc("aws_s3_bucket", {"tags": tags})])
	contains(m, "public_access_block")
}

test_lambda_caps if {
	count(gca.deny) >= 2 with input as plan([rc("aws_lambda_function", {"tags": tags, "memory_size": 4096, "timeout": 900})])
}

test_public_url_needs_declaration if {
	some m in gca.deny with input as plan([
		rc("aws_lambda_function", {"tags": object.union(tags, {"exposure": "private"}), "memory_size": 128, "timeout": 5}),
		rc("aws_lambda_function_url", {"authorization_type": "NONE"}),
	])
	contains(m, "exposure=public")
}

test_delete_foreign_resource_blocked if {
	r := {"address": "aws_lambda_function.y", "type": "aws_lambda_function", "change": {"actions": ["delete"], "before": {"tags": {}}, "after": null}}
	some m in gca.deny with input as plan([r])
	contains(m, "refusing to delete")
}

test_region_blocked if {
	p := {"resource_changes": [], "configuration": {"provider_config": {"aws": {"expressions": {"region": {"constant_value": "ap-south-1"}}}}}}
	some m in gca.deny with input as p
	contains(m, "region")
}

test_expiry_cap if {
	some m in gca.deny with input as plan([rc("aws_lambda_function", {"tags": object.union(tags, {"gca-expires": "2099-01-01T00:00:00Z"}), "memory_size": 128, "timeout": 5})])
	contains(m, "7 days")
}

test_ssh_open_blocked if {
	some m in gca.deny with input as plan([rc("aws_security_group", {"tags": tags, "ingress": [{"from_port": 22, "to_port": 22, "cidr_blocks": ["0.0.0.0/0"]}]})])
	contains(m, "port 22")
}

test_http_open_allowed if {
	count(gca.deny) == 0 with input as plan([rc("aws_security_group", {"tags": tags, "ingress": [{"from_port": 80, "to_port": 80, "cidr_blocks": ["0.0.0.0/0"]}]})])
}

test_big_task_blocked if {
	count(gca.deny) >= 2 with input as plan([rc("aws_ecs_task_definition", {"tags": tags, "cpu": "4096", "memory": "16384", "container_definitions": "[{\"image\":\"nginx\"}]"})])
}

test_foreign_image_blocked if {
	some m in gca.deny with input as plan([rc("aws_ecs_task_definition", {"tags": tags, "cpu": "256", "memory": "512", "container_definitions": "[{\"image\":\"evil/miner:latest\"}]"})])
	contains(m, "runner image")
}

test_unknown_policy_blocked if {
	r := {"address": "aws_iam_role_policy.p", "type": "aws_iam_role_policy", "change": {"actions": ["create"], "before": null, "after": {}, "after_unknown": {"policy": true}}}
	some m in gca.deny with input as plan([r])
	contains(m, "not known at plan time")
}

test_cloudfront_price_class if {
	some m in gca.deny with input as plan([rc("aws_cloudfront_distribution", {"tags": tags, "price_class": "PriceClass_All"})])
	contains(m, "PriceClass_100")
}

test_bucket_policy_foreign_principal if {
	pol := json.marshal({"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "x"}]})
	some m in gca.deny with input as plan([rc("aws_s3_bucket_policy", {"policy": pol})])
	contains(m, "cloudfront")
}

test_bucket_name_prefix if {
	some m in gca.deny with input as plan([rc("aws_s3_bucket", {"tags": tags, "bucket": "my-bucket"})])
	contains(m, "gca-app-")
}
