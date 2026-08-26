import csv
import io
import json
import os
import time
import urllib.parse
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "NHIGovernance")
STALE_DAYS = int(os.environ.get("STALE_THRESHOLD_DAYS", "90"))


def _parse_date(value):
    if not value or value in ("N/A", "no_information", "not_supported"):
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _days_since(dt):
    if dt is None:
        return None
    return (datetime.now(timezone.utc) - dt).days


def _get_credential_report(iam):
    # Report generation is asynchronous; poll until it's ready.
    for _ in range(10):
        try:
            resp = iam.generate_credential_report()
            if resp.get("State") == "COMPLETE":
                break
        except ClientError:
            pass
        time.sleep(2)
    report = iam.get_credential_report()
    csv_text = report["Content"].decode("utf-8")
    return list(csv.DictReader(io.StringIO(csv_text)))


def _scan_credential_report(rows, findings):
    stale_keys = 0
    total_active_keys = 0
    users_without_mfa = 0
    inactive_users = 0

    for row in rows:
        user = row.get("user")
        if user == "<root_account>":
            continue

        if row.get("password_enabled") == "true" and row.get("mfa_active") == "false":
            users_without_mfa += 1
            findings.append(f"NO_MFA user={user}")

        key_used_recently = False
        for slot in ("1", "2"):
            if row.get(f"access_key_{slot}_active") != "true":
                continue
            total_active_keys += 1

            rotated_age = _days_since(_parse_date(row.get(f"access_key_{slot}_last_rotated")))
            if rotated_age is not None and rotated_age > STALE_DAYS:
                stale_keys += 1
                findings.append(f"STALE_ACCESS_KEY user={user} key_slot={slot} age_days={rotated_age}")

            used_age = _days_since(_parse_date(row.get(f"access_key_{slot}_last_used_date")))
            if used_age is not None and used_age <= STALE_DAYS:
                key_used_recently = True

        password_age = _days_since(_parse_date(row.get("password_last_used")))
        password_recent = password_age is not None and password_age <= STALE_DAYS

        user_age = _days_since(_parse_date(row.get("user_creation_time")))
        if user_age is not None and user_age > STALE_DAYS and not key_used_recently and not password_recent:
            inactive_users += 1
            findings.append(f"INACTIVE_USER user={user} account_age_days={user_age}")

    return {
        "StaleAccessKeys": stale_keys,
        "TotalActiveAccessKeys": total_active_keys,
        "UsersWithoutMfa": users_without_mfa,
        "InactiveIamUsers": inactive_users,
    }


def _has_external_trust(trust_doc_raw, account_id):
    try:
        trust_doc = json.loads(urllib.parse.unquote(trust_doc_raw)) if isinstance(trust_doc_raw, str) else trust_doc_raw
    except (ValueError, TypeError):
        return False

    for stmt in trust_doc.get("Statement", []):
        principal = stmt.get("Principal", {})
        aws_principals = principal.get("AWS") if isinstance(principal, dict) else None
        if aws_principals is None:
            continue
        if isinstance(aws_principals, str):
            aws_principals = [aws_principals]
        for p in aws_principals:
            if p == "*":
                return True
            if p.startswith("arn:") and f":{account_id}:" not in p and account_id not in p:
                return True
    return False


def _scan_roles(iam, account_id, findings):
    total_roles = 0
    stale_roles = 0
    external_trust_roles = 0

    for page in iam.get_paginator("list_roles").paginate():
        for role in page["Roles"]:
            if role["Path"].startswith("/aws-service-role/"):
                continue  # AWS-managed service-linked roles aren't useful NHI targets
            total_roles += 1

            last_used = role.get("RoleLastUsed", {}).get("LastUsedDate")
            if last_used is None:
                stale_roles += 1
                findings.append(f"STALE_ROLE role={role['RoleName']} reason=never_used")
            else:
                age = (datetime.now(timezone.utc) - last_used).days
                if age > STALE_DAYS:
                    stale_roles += 1
                    findings.append(f"STALE_ROLE role={role['RoleName']} age_days={age}")

            if _has_external_trust(role.get("AssumeRolePolicyDocument"), account_id):
                external_trust_roles += 1
                findings.append(f"EXTERNAL_TRUST_ROLE role={role['RoleName']}")

    return {
        "TotalIamRoles": total_roles,
        "StaleIamRoles": stale_roles,
        "ExternalTrustRoles": external_trust_roles,
    }


def _scan_identity_providers(iam):
    oidc = len(iam.list_open_id_connect_providers().get("OpenIDConnectProviderList", []))
    saml = len(iam.list_saml_providers().get("SAMLProviderList", []))
    return {"OidcProviders": oidc, "SamlProviders": saml}


def _scan_secrets_rotation(regions, findings):
    per_region = {}
    for region in regions:
        try:
            sm = boto3.client("secretsmanager", region_name=region)
            count = 0
            for page in sm.get_paginator("list_secrets").paginate():
                for secret in page["SecretList"]:
                    if not secret.get("RotationEnabled", False):
                        count += 1
                        findings.append(f"SECRET_NO_ROTATION region={region} name={secret['Name']}")
            per_region[region] = count
        except ClientError as exc:
            print(f"Secrets Manager scan skipped for {region}: {exc}")
    return per_region


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def handler(event, context):
    sts = boto3.client("sts")
    account_id = sts.get_caller_identity()["Account"]

    iam = boto3.client("iam")
    findings = []

    rows = _get_credential_report(iam)
    credential_metrics = _scan_credential_report(rows, findings)
    role_metrics = _scan_roles(iam, account_id, findings)
    provider_metrics = _scan_identity_providers(iam)

    ec2 = boto3.client("ec2")
    regions = [r["RegionName"] for r in ec2.describe_regions(AllRegions=False)["Regions"]]
    secrets_by_region = _scan_secrets_rotation(regions, findings)

    metric_data = []
    for metric_name, value in {**credential_metrics, **role_metrics, **provider_metrics}.items():
        metric_data.append({
            "MetricName": metric_name,
            "Value": value,
            "Unit": "Count",
        })

    for region, count in secrets_by_region.items():
        metric_data.append({
            "MetricName": "SecretsWithoutRotation",
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
        "metrics_published": len(metric_data),
        "findings": len(findings),
        "regions_scanned_for_secrets": len(regions),
    }
