import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FedRAMP20xAudit")

# This collector fills the gaps the other six dashboards in this repo don't
# already cover: AWS Config recorder/rule compliance, CloudTrail health,
# AWS Backup plan coverage and job outcomes, and IAM Access Analyzer external-
# access findings. It does NOT duplicate MFA/stale-key checks (already in
# nhi-governance-dashboard), open-security-group/public-resource checks
# (already in network-exposure-dashboard), or Security Hub/GuardDuty finding
# counts (already in security-posture-dashboard). See README.md in this
# folder for the full KSI-to-metric mapping across all seven dashboards.


def _check_config(config, findings):
    metrics = {"ConfigRecorderEnabled": 0, "ConfigRulesCompliant": 0, "ConfigRulesNonCompliant": 0}
    try:
        recorders = config.describe_configuration_recorders().get("ConfigurationRecorders", [])
        statuses = config.describe_configuration_recorder_status().get("ConfigurationRecordersStatus", [])
        recording = any(s.get("recording") for s in statuses)
        metrics["ConfigRecorderEnabled"] = 1 if recorders and recording else 0
        if not metrics["ConfigRecorderEnabled"]:
            findings.append("CONFIG_RECORDER_NOT_ACTIVE")
    except ClientError as exc:
        print(f"Config recorder check failed: {exc}")

    try:
        paginator = config.get_paginator("describe_compliance_by_config_rule")
        for page in paginator.paginate():
            for rule in page.get("ComplianceByConfigRules", []):
                status = rule.get("Compliance", {}).get("ComplianceType")
                if status == "NON_COMPLIANT":
                    metrics["ConfigRulesNonCompliant"] += 1
                    findings.append(f"CONFIG_RULE_NON_COMPLIANT rule={rule.get('ConfigRuleName')}")
                elif status == "COMPLIANT":
                    metrics["ConfigRulesCompliant"] += 1
    except ClientError as exc:
        print(f"Config rule compliance check failed: {exc}")

    return metrics


def _check_cloudtrail(cloudtrail, findings):
    metrics = {
        "CloudTrailMultiRegionEnabled": 0,
        "CloudTrailLogFileValidationEnabled": 0,
        "CloudTrailLoggingActive": 0,
    }
    try:
        trails = cloudtrail.describe_trails(includeShadowTrails=False).get("trailList", [])
        if not trails:
            findings.append("NO_CLOUDTRAIL_TRAILS")
        for trail in trails:
            if trail.get("IsMultiRegionTrail"):
                metrics["CloudTrailMultiRegionEnabled"] = 1
            if trail.get("LogFileValidationEnabled"):
                metrics["CloudTrailLogFileValidationEnabled"] = 1
            try:
                status = cloudtrail.get_trail_status(Name=trail["TrailARN"])
                if status.get("IsLogging"):
                    metrics["CloudTrailLoggingActive"] = 1
            except ClientError as exc:
                print(f"get_trail_status failed for {trail.get('Name')}: {exc}")
    except ClientError as exc:
        print(f"CloudTrail check failed: {exc}")

    return metrics


def _check_backups(backup, findings):
    metrics = {"BackupPlansCount": 0, "BackupJobsSucceeded24h": 0, "BackupJobsFailed24h": 0}
    try:
        plans = backup.list_backup_plans().get("BackupPlansList", [])
        metrics["BackupPlansCount"] = len(plans)
        if not plans:
            findings.append("NO_BACKUP_PLANS")
    except ClientError as exc:
        print(f"Backup plan check failed: {exc}")

    since = datetime.now(timezone.utc) - timedelta(days=1)
    try:
        paginator = backup.get_paginator("list_backup_jobs")
        for page in paginator.paginate(ByCreatedAfter=since):
            for job in page.get("BackupJobs", []):
                state = job.get("State")
                if state == "FAILED":
                    metrics["BackupJobsFailed24h"] += 1
                    findings.append(f"BACKUP_JOB_FAILED resource={job.get('ResourceArn')}")
                elif state == "COMPLETED":
                    metrics["BackupJobsSucceeded24h"] += 1
    except ClientError as exc:
        print(f"Backup job check failed: {exc}")

    return metrics


def _check_access_analyzer(analyzer_client, findings):
    metrics = {"AccessAnalyzerActive": 0, "AccessAnalyzerExternalAccessFindings": 0}
    try:
        analyzers = analyzer_client.list_analyzers(type="ACCOUNT").get("analyzers", [])
        active = [a for a in analyzers if a.get("status") == "ACTIVE"]
        metrics["AccessAnalyzerActive"] = 1 if active else 0
        if not active:
            findings.append("NO_ACTIVE_ACCESS_ANALYZER")
            return metrics

        for analyzer in active:
            try:
                paginator = analyzer_client.get_paginator("list_findings")
                for page in paginator.paginate(
                    analyzerArn=analyzer["arn"], filter={"status": {"eq": ["ACTIVE"]}}
                ):
                    for finding in page.get("findings", []):
                        metrics["AccessAnalyzerExternalAccessFindings"] += 1
                        findings.append(f"EXTERNAL_ACCESS_FINDING resource={finding.get('resource')}")
            except ClientError as exc:
                print(f"list_findings failed for {analyzer['arn']}: {exc}")
    except ClientError as exc:
        print(f"Access Analyzer check failed: {exc}")

    return metrics


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def handler(event, context):
    findings = []

    config = boto3.client("config")
    cloudtrail = boto3.client("cloudtrail")
    backup = boto3.client("backup")
    analyzer = boto3.client("accessanalyzer")

    metrics = {}
    metrics.update(_check_config(config, findings))
    metrics.update(_check_cloudtrail(cloudtrail, findings))
    metrics.update(_check_backups(backup, findings))
    metrics.update(_check_access_analyzer(analyzer, findings))

    metric_data = [
        {"MetricName": name, "Value": value, "Unit": "Count"} for name, value in metrics.items()
    ]

    cw = boto3.client("cloudwatch")
    for batch in chunked(metric_data, 20):
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=batch)

    for line in findings:
        print(line)

    return {"metrics_published": len(metric_data), "findings": len(findings)}
