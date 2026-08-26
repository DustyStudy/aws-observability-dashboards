import os
import datetime
import boto3

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockCostObservability")


def handler(event, context):
    # Cost Explorer is only ever queried via its us-east-1 endpoint,
    # regardless of which region this function runs in.
    ce = boto3.client("ce", region_name="us-east-1")
    cw = boto3.client("cloudwatch")

    end = datetime.date.today()
    start = end - datetime.timedelta(days=1)

    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        Filter={"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Bedrock"]}},
        GroupBy=[{"Type": "DIMENSION", "Key": "USAGE_TYPE"}],
    )

    metric_data = []
    total = 0.0
    for result in response.get("ResultsByTime", []):
        for group in result.get("Groups", []):
            usage_type = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            total += amount
            metric_data.append({
                "MetricName": "EstimatedDailyCostUSD",
                "Dimensions": [{"Name": "UsageType", "Value": usage_type}],
                "Value": amount,
                "Unit": "None",
            })

    metric_data.append({
        "MetricName": "EstimatedDailyCostUSD",
        "Dimensions": [{"Name": "UsageType", "Value": "TOTAL"}],
        "Value": total,
        "Unit": "None",
    })

    if metric_data:
        # put_metric_data accepts up to 1000 metrics per call; a single
        # day of Bedrock usage types is well under that.
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=metric_data)

    return {"published_metrics": len(metric_data), "total_cost_usd": total}
