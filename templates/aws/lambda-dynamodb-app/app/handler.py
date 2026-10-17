import json
import os
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def handler(event, context):
    """Example: GET / lists items; POST / stores {"id": "...", ...}. Items use pk/sk string keys."""
    method = event["requestContext"]["http"]["method"]
    if method == "POST":
        body = json.loads(event.get("body") or "{}")
        table.put_item(Item={"pk": "item", "sk": str(body.get("id", "1")), **body})
        return {"statusCode": 201, "headers": {"content-type": "application/json"}, "body": json.dumps({"stored": True})}
    items = table.query(KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq("item"))["Items"]
    return {"statusCode": 200, "headers": {"content-type": "application/json"}, "body": json.dumps(items, default=str)}
