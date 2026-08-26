import os
import boto3

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "AIServiceInventory")

# Label -> CloudWatch namespace to probe for activity in each region.
SERVICES = {
    "Bedrock": "AWS/Bedrock",
    "BedrockAgents": "AWS/Bedrock/Agents",
    "BedrockGuardrails": "AWS/Bedrock/Guardrails",
    "Rekognition": "AWS/Rekognition",
    "Comprehend": "AWS/Comprehend",
    "Textract": "AWS/Textract",
}


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def handler(event, context):
    ec2 = boto3.client("ec2")
    regions = [r["RegionName"] for r in ec2.describe_regions(AllRegions=False)["Regions"]]

    metric_data = []
    for region in regions:
        region_cw = boto3.client("cloudwatch", region_name=region)
        for service_label, namespace in SERVICES.items():
            try:
                resp = region_cw.list_metrics(Namespace=namespace)
                is_active = len(resp.get("Metrics", [])) > 0
            except Exception:
                # A region/namespace combo erroring (e.g. opt-in region
                # without the service) counts as inactive, not a failure
                # of the whole scan.
                is_active = False

            metric_data.append({
                "MetricName": "ServiceActive",
                "Dimensions": [
                    {"Name": "Service", "Value": service_label},
                    {"Name": "Region", "Value": region},
                ],
                "Value": 1 if is_active else 0,
                "Unit": "None",
            })

    home_cw = boto3.client("cloudwatch")
    for batch in chunked(metric_data, 20):
        home_cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=batch)

    return {"regions_checked": len(regions), "metrics_published": len(metric_data)}
