import os
import boto3
from botocore.exceptions import ClientError

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "NetworkExposure")

# Ports we treat as sensitive enough to call out separately from "any
# open-to-the-internet rule". Extend this set to fit your environment.
SENSITIVE_PORTS = {22, 3389, 3306, 5432, 1433, 27017, 6379, 9200, 5900}


def _is_open_rule(perm):
    for ip_range in perm.get("IpRanges", []):
        if ip_range.get("CidrIp") == "0.0.0.0/0":
            return True
    for ip_range in perm.get("Ipv6Ranges", []):
        if ip_range.get("CidrIpv6") == "::/0":
            return True
    return False


def _rule_ports(perm):
    from_port = perm.get("FromPort")
    to_port = perm.get("ToPort")
    if from_port is None or to_port is None:
        # No port range means the rule covers all ports (e.g. -1 = all traffic)
        return set(range(0, 65536))
    return set(range(from_port, to_port + 1))


def scan_region(region, findings):
    ec2 = boto3.client("ec2", region_name=region)
    open_rules = 0
    open_sensitive_rules = 0

    for page in ec2.get_paginator("describe_security_groups").paginate():
        for sg in page["SecurityGroups"]:
            for perm in sg.get("IpPermissions", []):
                if _is_open_rule(perm):
                    open_rules += 1
                    if _rule_ports(perm) & SENSITIVE_PORTS:
                        open_sensitive_rules += 1
                        findings.append(
                            f"OPEN_SENSITIVE_SG region={region} group={sg['GroupId']} name={sg.get('GroupName')}"
                        )

    public_instances = 0
    for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running", "stopped"]}]
    ):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                if instance.get("PublicIpAddress"):
                    public_instances += 1
                    findings.append(f"PUBLIC_EC2 region={region} instance={instance['InstanceId']}")

    public_rds = 0
    try:
        rds = boto3.client("rds", region_name=region)
        for page in rds.get_paginator("describe_db_instances").paginate():
            for db in page["DBInstances"]:
                if db.get("PubliclyAccessible"):
                    public_rds += 1
                    findings.append(f"PUBLIC_RDS region={region} instance={db['DBInstanceIdentifier']}")
    except ClientError as exc:
        print(f"RDS scan skipped for {region}: {exc}")

    internet_facing_lbs = 0
    try:
        elbv2 = boto3.client("elbv2", region_name=region)
        for page in elbv2.get_paginator("describe_load_balancers").paginate():
            for lb in page["LoadBalancers"]:
                if lb.get("Scheme") == "internet-facing":
                    internet_facing_lbs += 1
                    findings.append(f"PUBLIC_LB region={region} lb={lb['LoadBalancerName']}")
    except ClientError as exc:
        print(f"ELBv2 scan skipped for {region}: {exc}")

    return {
        "OpenSecurityGroupRules": open_rules,
        "OpenSensitivePortRules": open_sensitive_rules,
        "PublicEc2Instances": public_instances,
        "PubliclyAccessibleRdsInstances": public_rds,
        "InternetFacingLoadBalancers": internet_facing_lbs,
    }


def scan_s3_buckets(findings):
    """S3 is a global service; buckets are counted by their home region."""
    s3 = boto3.client("s3")
    region_counts = {}
    try:
        buckets = s3.list_buckets().get("Buckets", [])
    except ClientError as exc:
        print(f"S3 bucket listing failed: {exc}")
        return region_counts

    for bucket in buckets:
        name = bucket["Name"]
        try:
            loc = s3.get_bucket_location(Bucket=name).get("LocationConstraint")
            bucket_region = loc or "us-east-1"
        except ClientError:
            bucket_region = "us-east-1"

        is_public = False
        try:
            status = s3.get_bucket_policy_status(Bucket=name)
            is_public = status["PolicyStatus"]["IsPublic"]
        except ClientError:
            pass

        if not is_public:
            try:
                acl = s3.get_bucket_acl(Bucket=name)
                for grant in acl.get("Grants", []):
                    if grant.get("Grantee", {}).get("URI", "").endswith("/AllUsers"):
                        is_public = True
                        break
            except ClientError:
                pass

        if is_public:
            findings.append(f"PUBLIC_S3 bucket={name} region={bucket_region}")
            region_counts[bucket_region] = region_counts.get(bucket_region, 0) + 1

    return region_counts


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def handler(event, context):
    ec2_home = boto3.client("ec2")
    regions = [r["RegionName"] for r in ec2_home.describe_regions(AllRegions=False)["Regions"]]

    findings = []
    metric_data = []

    for region in regions:
        try:
            counts = scan_region(region, findings)
        except ClientError as exc:
            print(f"Region scan failed for {region}: {exc}")
            continue
        for metric_name, value in counts.items():
            metric_data.append({
                "MetricName": metric_name,
                "Dimensions": [{"Name": "Region", "Value": region}],
                "Value": value,
                "Unit": "Count",
            })

    for region, count in scan_s3_buckets(findings).items():
        metric_data.append({
            "MetricName": "PubliclyAccessibleS3Buckets",
            "Dimensions": [{"Name": "Region", "Value": region}],
            "Value": count,
            "Unit": "Count",
        })

    cw = boto3.client("cloudwatch")
    for batch in chunked(metric_data, 20):
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=batch)

    for line in findings:
        print(line)

    return {
        "regions_scanned": len(regions),
        "metrics_published": len(metric_data),
        "findings": len(findings),
    }
