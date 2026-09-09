import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FedRAMP20xAudit")

# This collector fills the gaps the other six dashboards in this repo don't
# already cover. First tranche: AWS Config recorder/rule compliance,
# CloudTrail health, AWS Backup plan coverage and job outcomes, and IAM
# Access Analyzer external-access findings. Second tranche (added after the
# first version shipped): RDS/ASG availability-zone coverage, AWS Config
# auto-remediation coverage, VPC endpoint/NACL posture, ACM certificate
# expiry and S3 secure-transport policies, a Security Hub standards score,
# account-wide Inspector findings (not just EKS), EC2 instances missing an
# IAM instance profile, and Trusted Advisor security-check status where the
# support plan allows it. Third tranche: whether GuardDuty/Security Hub/
# Inspector are actually turned ON (a finding *count* of zero looks
# identical whether an account is clean or the detector was never enabled —
# this closes that blind spot), account-level EBS encryption-by-default,
# RDS storage encryption, S3 account-level Block Public Access, and IAM
# account password policy strength. It does NOT duplicate MFA/stale-key
# checks (already in nhi-governance-dashboard), open-security-group/
# public-resource checks (already in network-exposure-dashboard), or
# Security Hub/GuardDuty finding *counts* (already in
# security-posture-dashboard) — the Security Hub check here is a different
# thing, a pass/fail *score* across enabled standards, and the detector
# checks here are about whether the service is running at all, not what it
# found. See README.md in this folder for the full KSI-to-metric mapping
# across all eight dashboards.


def _check_config(config, findings, non_compliant_rule_names=None):
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
                rule_name = rule.get("ConfigRuleName")
                if status == "NON_COMPLIANT":
                    metrics["ConfigRulesNonCompliant"] += 1
                    findings.append(f"CONFIG_RULE_NON_COMPLIANT rule={rule_name}")
                    if non_compliant_rule_names is not None:
                        non_compliant_rule_names.append(rule_name)
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


def _check_high_availability(rds, autoscaling, findings):
    """KSI-CNA-OFA: are resources optimized for HA and rapid recovery."""
    metrics = {"RdsInstancesNotMultiAz": 0, "AsgSingleAzCount": 0}
    try:
        paginator = rds.get_paginator("describe_db_instances")
        for page in paginator.paginate():
            for db in page.get("DBInstances", []):
                if not db.get("MultiAZ", False):
                    metrics["RdsInstancesNotMultiAz"] += 1
                    findings.append(f"RDS_NOT_MULTI_AZ instance={db.get('DBInstanceIdentifier')}")
    except ClientError as exc:
        print(f"RDS Multi-AZ check failed: {exc}")

    try:
        paginator = autoscaling.get_paginator("describe_auto_scaling_groups")
        for page in paginator.paginate():
            for asg in page.get("AutoScalingGroups", []):
                if len(set(asg.get("AvailabilityZones", []))) < 2:
                    metrics["AsgSingleAzCount"] += 1
                    findings.append(f"ASG_SINGLE_AZ name={asg.get('AutoScalingGroupName')}")
    except ClientError as exc:
        print(f"ASG availability-zone check failed: {exc}")

    return metrics


def _check_auto_remediation(config, non_compliant_rule_names, findings):
    """KSI-CNA-EIS: are non-compliant resources automatically brought back to their intended state."""
    metrics = {"ConfigRulesWithRemediation": 0, "ConfigRulesWithoutRemediation": 0}
    if not non_compliant_rule_names:
        return metrics
    try:
        resp = config.describe_remediation_configurations(ConfigRuleNames=non_compliant_rule_names)
        remediated = {r["ConfigRuleName"] for r in resp.get("RemediationConfigurations", [])}
        for name in non_compliant_rule_names:
            if name in remediated:
                metrics["ConfigRulesWithRemediation"] += 1
            else:
                metrics["ConfigRulesWithoutRemediation"] += 1
                findings.append(f"CONFIG_RULE_NO_REMEDIATION rule={name}")
    except ClientError as exc:
        print(f"Remediation configuration check failed: {exc}")
    return metrics


def _check_network_segmentation(ec2, findings):
    """KSI-CNA-ULN: is logical networking used and reviewed to enforce traffic flow controls."""
    metrics = {"VpcEndpointsCount": 0, "VpcsWithoutCustomNacl": 0}
    try:
        metrics["VpcEndpointsCount"] = len(ec2.describe_vpc_endpoints().get("VpcEndpoints", []))
    except ClientError as exc:
        print(f"VPC endpoint check failed: {exc}")

    try:
        vpc_ids = {v["VpcId"] for v in ec2.describe_vpcs().get("Vpcs", [])}
        nacls = ec2.describe_network_acls().get("NetworkAcls", [])
        vpcs_with_custom_nacl = {n["VpcId"] for n in nacls if not n.get("IsDefault", False)}
        for vpc_id in vpc_ids:
            if vpc_id not in vpcs_with_custom_nacl:
                metrics["VpcsWithoutCustomNacl"] += 1
                findings.append(f"VPC_DEFAULT_NACL_ONLY vpc={vpc_id}")
    except ClientError as exc:
        print(f"NACL check failed: {exc}")

    return metrics


def _denies_insecure_transport(stmt):
    value = stmt.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport")
    if isinstance(value, list):
        return "false" in value
    return value == "false"


def _check_secure_communications(acm, s3, findings):
    """KSI-SVC-VCM: is the authenticity/integrity of communications validated."""
    metrics = {"AcmCertsExpiringSoon": 0, "S3BucketsWithoutSecureTransportPolicy": 0}
    expiry_cutoff = datetime.now(timezone.utc) + timedelta(days=30)

    try:
        paginator = acm.get_paginator("list_certificates")
        for page in paginator.paginate(CertificateStatuses=["ISSUED"]):
            for cert in page.get("CertificateSummaryList", []):
                try:
                    detail = acm.describe_certificate(CertificateArn=cert["CertificateArn"])["Certificate"]
                    not_after = detail.get("NotAfter")
                    if not_after and not_after <= expiry_cutoff:
                        metrics["AcmCertsExpiringSoon"] += 1
                        findings.append(f"ACM_CERT_EXPIRING domain={detail.get('DomainName')}")
                except ClientError as exc:
                    print(f"describe_certificate failed for {cert.get('CertificateArn')}: {exc}")
    except ClientError as exc:
        print(f"ACM certificate check failed: {exc}")

    try:
        for bucket in s3.list_buckets().get("Buckets", []):
            name = bucket["Name"]
            secure = False
            try:
                policy = json.loads(s3.get_bucket_policy(Bucket=name)["Policy"])
                secure = any(
                    stmt.get("Effect") == "Deny" and _denies_insecure_transport(stmt)
                    for stmt in policy.get("Statement", [])
                )
            except ClientError:
                pass  # No bucket policy at all -> definitely not secured this way
            if not secure:
                metrics["S3BucketsWithoutSecureTransportPolicy"] += 1
                findings.append(f"S3_NO_SECURE_TRANSPORT_POLICY bucket={name}")
    except ClientError as exc:
        print(f"S3 secure-transport check failed: {exc}")

    return metrics


def _check_security_hub_score(securityhub, findings):
    """KSI-SVC-EIS: are opportunities to improve security persistently evaluated and made."""
    metrics = {"SecurityHubStandardsScorePercent": 0, "SecurityHubControlsEvaluated": 0}
    passed = 0
    failed = 0
    try:
        paginator = securityhub.get_paginator("get_findings")
        for page in paginator.paginate(
            Filters={
                "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}],
                "ComplianceStatus": [
                    {"Value": "PASSED", "Comparison": "EQUALS"},
                    {"Value": "FAILED", "Comparison": "EQUALS"},
                ],
            }
        ):
            for finding in page.get("Findings", []):
                status = finding.get("Compliance", {}).get("Status")
                if status == "PASSED":
                    passed += 1
                elif status == "FAILED":
                    failed += 1
                    findings.append(f"SECURITY_HUB_CONTROL_FAILED id={finding.get('GeneratorId')}")
    except ClientError as exc:
        print(f"Security Hub score check failed: {exc}")

    total = passed + failed
    metrics["SecurityHubControlsEvaluated"] = total
    metrics["SecurityHubStandardsScorePercent"] = round((passed / total) * 100) if total else 0
    return metrics


def _check_inspector_findings(inspector2, findings):
    """KSI-SCR-MON, account-wide: upstream vulnerability monitoring beyond just EKS/ECR."""
    metrics = {"Inspector2CriticalFindings": 0, "Inspector2HighFindings": 0}
    try:
        paginator = inspector2.get_paginator("list_findings")
        for page in paginator.paginate(
            filterCriteria={
                "severity": [
                    {"comparison": "EQUALS", "value": "CRITICAL"},
                    {"comparison": "EQUALS", "value": "HIGH"},
                ],
                "findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}],
            }
        ):
            for finding in page.get("findings", []):
                severity = finding.get("severity")
                if severity == "CRITICAL":
                    metrics["Inspector2CriticalFindings"] += 1
                    findings.append(f"INSPECTOR_FINDING severity=CRITICAL arn={finding.get('findingArn')}")
                elif severity == "HIGH":
                    metrics["Inspector2HighFindings"] += 1
                    findings.append(f"INSPECTOR_FINDING severity=HIGH arn={finding.get('findingArn')}")
    except ClientError as exc:
        print(f"Inspector2 findings check failed: {exc}")

    return metrics


def _check_non_user_auth(ec2, findings):
    """KSI-IAM-SNU: are appropriately secure authentication methods used for non-user accounts/services."""
    metrics = {"Ec2InstancesWithoutInstanceProfile": 0}
    try:
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(
            Filters=[{"Name": "instance-state-name", "Values": ["running", "stopped"]}]
        ):
            for reservation in page.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    if not instance.get("IamInstanceProfile"):
                        metrics["Ec2InstancesWithoutInstanceProfile"] += 1
                        findings.append(f"EC2_NO_INSTANCE_PROFILE instance={instance.get('InstanceId')}")
    except ClientError as exc:
        print(f"EC2 instance-profile check failed: {exc}")

    return metrics


def _check_trusted_advisor(support, findings):
    """KSI-CNA-IBP: is configuration persistently compared against provider best-practice guidance.

    Requires a Business or Enterprise support plan -- Basic/Developer plans
    get a SubscriptionRequiredException, which is reported as
    TrustedAdvisorAvailable=0 rather than an error, since that's itself
    useful signal (an assessor may ask why it's unavailable).
    """
    metrics = {"TrustedAdvisorAvailable": 0, "TrustedAdvisorSecurityChecksFlagged": 0}
    try:
        checks = support.describe_trusted_advisor_checks(language="en").get("checks", [])
        metrics["TrustedAdvisorAvailable"] = 1
        for check in (c for c in checks if c.get("category") == "security"):
            try:
                result = support.describe_trusted_advisor_check_result(
                    checkId=check["id"], language="en"
                ).get("result", {})
                if result.get("status") in ("error", "warning"):
                    metrics["TrustedAdvisorSecurityChecksFlagged"] += 1
                    findings.append(
                        f"TRUSTED_ADVISOR_FLAGGED check={check.get('name')} status={result.get('status')}"
                    )
            except ClientError as exc:
                print(f"describe_trusted_advisor_check_result failed for {check.get('id')}: {exc}")
    except ClientError as exc:
        print(f"Trusted Advisor unavailable (requires Business/Enterprise support): {exc}")

    return metrics


def _check_detector_status(guardduty, securityhub, inspector2, findings):
    """Is the detection tooling itself actually running, not just what it found.

    A finding count of zero looks identical whether the account is clean or
    the detector was never turned on -- this check exists specifically to
    close that blind spot for GuardDuty, Security Hub, and Inspector2.
    """
    metrics = {"GuardDutyEnabled": 0, "SecurityHubEnabled": 0, "Inspector2Enabled": 0}

    try:
        detector_ids = guardduty.list_detectors().get("DetectorIds", [])
        if not detector_ids:
            findings.append("GUARDDUTY_NOT_ENABLED")
        else:
            detail = guardduty.get_detector(DetectorId=detector_ids[0])
            if detail.get("Status") == "ENABLED":
                metrics["GuardDutyEnabled"] = 1
            else:
                findings.append("GUARDDUTY_DETECTOR_SUSPENDED")
    except ClientError as exc:
        print(f"GuardDuty detector-status check failed: {exc}")
        findings.append("GUARDDUTY_NOT_ENABLED")

    try:
        securityhub.describe_hub()
        metrics["SecurityHubEnabled"] = 1
    except ClientError as exc:
        print(f"Security Hub not enabled: {exc}")
        findings.append("SECURITY_HUB_NOT_ENABLED")

    try:
        status = inspector2.batch_get_account_status().get("accounts", [])
        resource_state = status[0].get("resourceState", {}) if status else {}
        if any(rs.get("status") == "ENABLED" for rs in resource_state.values()):
            metrics["Inspector2Enabled"] = 1
        else:
            findings.append("INSPECTOR2_NOT_ENABLED")
    except ClientError as exc:
        print(f"Inspector2 account-status check failed: {exc}")
        findings.append("INSPECTOR2_NOT_ENABLED")

    return metrics


def _check_account_encryption_defaults(ec2, rds, s3control, account_id, findings):
    """KSI-SVC-SIN, account-wide defaults: EBS/RDS encryption and S3 public-access blocking."""
    metrics = {
        "EbsEncryptionByDefaultEnabled": 0,
        "RdsInstancesUnencrypted": 0,
        "S3AccountBlockPublicAccessEnabled": 0,
    }

    try:
        if ec2.get_ebs_encryption_by_default().get("EbsEncryptionByDefault"):
            metrics["EbsEncryptionByDefaultEnabled"] = 1
        else:
            findings.append("EBS_ENCRYPTION_BY_DEFAULT_DISABLED")
    except ClientError as exc:
        print(f"EBS encryption-by-default check failed: {exc}")

    try:
        paginator = rds.get_paginator("describe_db_instances")
        for page in paginator.paginate():
            for db in page.get("DBInstances", []):
                if not db.get("StorageEncrypted", False):
                    metrics["RdsInstancesUnencrypted"] += 1
                    findings.append(f"RDS_STORAGE_UNENCRYPTED instance={db.get('DBInstanceIdentifier')}")
    except ClientError as exc:
        print(f"RDS storage-encryption check failed: {exc}")

    try:
        config = s3control.get_public_access_block(AccountId=account_id).get(
            "PublicAccessBlockConfiguration", {}
        )
        if all(
            config.get(key, False)
            for key in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
        ):
            metrics["S3AccountBlockPublicAccessEnabled"] = 1
        else:
            findings.append("S3_ACCOUNT_BLOCK_PUBLIC_ACCESS_PARTIAL")
    except ClientError as exc:
        # NoSuchPublicAccessBlockConfiguration means it was never configured at all.
        print(f"S3 account-level Block Public Access check failed: {exc}")
        findings.append("S3_ACCOUNT_BLOCK_PUBLIC_ACCESS_NOT_CONFIGURED")

    return metrics


def _check_password_policy(iam, findings):
    """KSI-IAM-APM: is a strong IAM account password policy enforced."""
    metrics = {"IamPasswordPolicyCompliant": 0}
    try:
        policy = iam.get_account_password_policy().get("PasswordPolicy", {})
        compliant = (
            policy.get("MinimumPasswordLength", 0) >= 14
            and policy.get("RequireSymbols", False)
            and policy.get("RequireNumbers", False)
            and policy.get("RequireUppercaseCharacters", False)
            and policy.get("RequireLowercaseCharacters", False)
            and (policy.get("MaxPasswordAge") or 9999) <= 90
            and (policy.get("PasswordReusePrevention") or 0) >= 24
        )
        if compliant:
            metrics["IamPasswordPolicyCompliant"] = 1
        else:
            findings.append("IAM_PASSWORD_POLICY_WEAK")
    except ClientError as exc:
        print(f"IAM password policy check failed: {exc}")
        findings.append("NO_IAM_PASSWORD_POLICY")

    return metrics


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def handler(event, context):
    findings = []
    non_compliant_rule_names = []

    config = boto3.client("config")
    cloudtrail = boto3.client("cloudtrail")
    backup = boto3.client("backup")
    analyzer = boto3.client("accessanalyzer")
    rds = boto3.client("rds")
    autoscaling = boto3.client("autoscaling")
    ec2 = boto3.client("ec2")
    acm = boto3.client("acm")
    s3 = boto3.client("s3")
    securityhub = boto3.client("securityhub")
    inspector2 = boto3.client("inspector2")
    # The Support API only has an endpoint in us-east-1, regardless of
    # which region this Lambda itself runs in.
    support = boto3.client("support", region_name="us-east-1")
    guardduty = boto3.client("guardduty")
    s3control = boto3.client("s3control")
    iam = boto3.client("iam")
    sts = boto3.client("sts")

    metrics = {}
    metrics.update(_check_config(config, findings, non_compliant_rule_names))
    metrics.update(_check_cloudtrail(cloudtrail, findings))
    metrics.update(_check_backups(backup, findings))
    metrics.update(_check_access_analyzer(analyzer, findings))
    metrics.update(_check_high_availability(rds, autoscaling, findings))
    metrics.update(_check_auto_remediation(config, non_compliant_rule_names, findings))
    metrics.update(_check_network_segmentation(ec2, findings))
    metrics.update(_check_secure_communications(acm, s3, findings))
    metrics.update(_check_security_hub_score(securityhub, findings))
    metrics.update(_check_inspector_findings(inspector2, findings))
    metrics.update(_check_non_user_auth(ec2, findings))
    metrics.update(_check_trusted_advisor(support, findings))
    metrics.update(_check_detector_status(guardduty, securityhub, inspector2, findings))
    metrics.update(_check_password_policy(iam, findings))

    try:
        account_id = sts.get_caller_identity()["Account"]
        metrics.update(_check_account_encryption_defaults(ec2, rds, s3control, account_id, findings))
    except ClientError as exc:
        print(f"Could not resolve account ID for S3 account-level checks: {exc}")

    metric_data = [
        {"MetricName": name, "Value": value, "Unit": "Count"} for name, value in metrics.items()
    ]

    cw = boto3.client("cloudwatch")
    for batch in chunked(metric_data, 20):
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=batch)

    for line in findings:
        print(line)

    return {"metrics_published": len(metric_data), "findings": len(findings)}
