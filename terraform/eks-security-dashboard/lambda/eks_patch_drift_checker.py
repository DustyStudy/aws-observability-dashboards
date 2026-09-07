"""
eks-security-dashboard: patch/version drift checker

Scans every EKS cluster and nodegroup in the account/region, compares
control-plane and nodegroup Kubernetes versions against a target "latest
supported" version, flags nodegroups whose AMI release is stale, and
publishes the results as custom CloudWatch metrics under the
EKS/Security namespace so the dashboard can graph them over time.

Env vars:
  LATEST_EKS_VERSION   - target Kubernetes version, e.g. "1.31" (required)
  STALE_AMI_DAYS        - age in days before a nodegroup AMI is "stale"
                           (default 60)
"""

import datetime
import os

import boto3

NAMESPACE = "EKS/Security"
LATEST_VERSION = os.environ.get("LATEST_EKS_VERSION", "1.31")
STALE_AMI_DAYS = int(os.environ.get("STALE_AMI_DAYS", "60"))


def _put_metric(cloudwatch, name, value, dimensions=None):
    datum = {
        "MetricName": name,
        "Value": float(value),
        "Unit": "Count",
        "Timestamp": datetime.datetime.utcnow(),
    }
    if dimensions:
        datum["Dimensions"] = dimensions
    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=[datum])


def lambda_handler(event, context):
    # Created here rather than at module import time so importing this
    # module (e.g. for unit tests) never requires a resolvable AWS region —
    # a real Lambda invocation always has one, but a local/CI Python
    # process doesn't.
    eks = boto3.client("eks")
    cloudwatch = boto3.client("cloudwatch")

    clusters = eks.list_clusters()["clusters"]

    version_drift = 0
    nodegroups_needing_update = 0
    nodegroup_health_issues = 0
    stale_ami_nodegroups = 0
    public_only_endpoint_clusters = 0

    for cluster_name in clusters:
        cluster = eks.describe_cluster(name=cluster_name)["cluster"]
        cluster_version = cluster.get("version")
        is_drifted = bool(cluster_version and cluster_version != LATEST_VERSION)
        if is_drifted:
            version_drift += 1

        vpc_config = cluster.get("resourcesVpcConfig", {})
        if vpc_config.get("endpointPublicAccess") and not vpc_config.get(
            "endpointPrivateAccess"
        ):
            public_only_endpoint_clusters += 1

        _put_metric(
            cloudwatch,
            "ClusterVersionDrift",
            1 if is_drifted else 0,
            dimensions=[{"Name": "ClusterName", "Value": cluster_name}],
        )

        nodegroups = eks.list_nodegroups(clusterName=cluster_name)["nodegroups"]
        for ng_name in nodegroups:
            ng = eks.describe_nodegroup(
                clusterName=cluster_name, nodegroupName=ng_name
            )["nodegroup"]

            ng_version = ng.get("version")
            if ng_version and ng_version != LATEST_VERSION:
                nodegroups_needing_update += 1

            issues = ng.get("health", {}).get("issues", [])
            if issues:
                nodegroup_health_issues += len(issues)

            release_version = ng.get("releaseVersion", "")
            if release_version:
                parts = release_version.split("-")
                if len(parts) >= 2:
                    date_str = parts[1]
                    try:
                        release_date = datetime.datetime.strptime(
                            date_str, "%Y%m%d"
                        )
                        age_days = (
                            datetime.datetime.utcnow() - release_date
                        ).days
                        if age_days > STALE_AMI_DAYS:
                            stale_ami_nodegroups += 1
                    except ValueError:
                        # Custom AMI or unexpected format; skip age check
                        pass

    _put_metric(cloudwatch, "ClustersScanned", len(clusters))
    _put_metric(cloudwatch, "ClusterVersionDriftCount", version_drift)
    _put_metric(cloudwatch, "PublicOnlyEndpointClusters", public_only_endpoint_clusters)
    _put_metric(cloudwatch, "NodegroupsNeedingUpdate", nodegroups_needing_update)
    _put_metric(cloudwatch, "NodegroupHealthIssues", nodegroup_health_issues)
    _put_metric(cloudwatch, "StaleAmiNodegroups", stale_ami_nodegroups)

    return {
        "statusCode": 200,
        "body": {
            "clustersScanned": len(clusters),
            "clusterVersionDriftCount": version_drift,
            "publicOnlyEndpointClusters": public_only_endpoint_clusters,
            "nodegroupsNeedingUpdate": nodegroups_needing_update,
            "nodegroupHealthIssues": nodegroup_health_issues,
            "staleAmiNodegroups": stale_ami_nodegroups,
        },
    }
