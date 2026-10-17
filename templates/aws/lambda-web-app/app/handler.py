def handler(event, context):
    return {"statusCode": 200, "headers": {"content-type": "text/html"},
            "body": "<h1>Hello from governed-cloud-agent</h1>"}
