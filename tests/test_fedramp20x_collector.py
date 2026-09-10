"""
Unit tests for fedramp20x_collector.py, with boto3.client mocked so no real
Config/CloudTrail/Backup/Access Analyzer/RDS/ASG/EC2/ACM/S3/Security Hub/
Inspector/Support/CloudWatch calls happen.
"""
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import fedramp20x_collector as collector
from fedramp20x_collector import ClientError


def test_chunked_basic():
    assert list(collector.chunked([1, 2, 3, 4, 5], 3)) == [[1, 2, 3], [4, 5]]


def test_check_config_flags_missing_recorder():
    config = MagicMock()
    config.describe_configuration_recorders.return_value = {"ConfigurationRecorders": []}
    config.describe_configuration_recorder_status.return_value = {"ConfigurationRecordersStatus": []}
    config.get_paginator.return_value.paginate.return_value = [{"ComplianceByConfigRules": []}]

    findings = []
    metrics = collector._check_config(config, findings)

    assert metrics["ConfigRecorderEnabled"] == 0
    assert "CONFIG_RECORDER_NOT_ACTIVE" in findings


def test_check_config_counts_compliance():
    config = MagicMock()
    config.describe_configuration_recorders.return_value = {"ConfigurationRecorders": [{"name": "default"}]}
    config.describe_configuration_recorder_status.return_value = {
        "ConfigurationRecordersStatus": [{"recording": True}]
    }
    config.get_paginator.return_value.paginate.return_value = [
        {
            "ComplianceByConfigRules": [
                {"ConfigRuleName": "r1", "Compliance": {"ComplianceType": "COMPLIANT"}},
                {"ConfigRuleName": "r2", "Compliance": {"ComplianceType": "NON_COMPLIANT"}},
                {"ConfigRuleName": "r3", "Compliance": {"ComplianceType": "NON_COMPLIANT"}},
            ]
        }
    ]

    findings = []
    metrics = collector._check_config(config, findings)

    assert metrics["ConfigRecorderEnabled"] == 1
    assert metrics["ConfigRulesCompliant"] == 1
    assert metrics["ConfigRulesNonCompliant"] == 2
    assert findings.count("CONFIG_RULE_NON_COMPLIANT rule=r2") == 1


def test_check_cloudtrail_flags_no_trails():
    cloudtrail = MagicMock()
    cloudtrail.describe_trails.return_value = {"trailList": []}

    findings = []
    metrics = collector._check_cloudtrail(cloudtrail, findings)

    assert metrics == {
        "CloudTrailMultiRegionEnabled": 0,
        "CloudTrailLogFileValidationEnabled": 0,
        "CloudTrailLoggingActive": 0,
    }
    assert "NO_CLOUDTRAIL_TRAILS" in findings


def test_check_cloudtrail_healthy_trail():
    cloudtrail = MagicMock()
    cloudtrail.describe_trails.return_value = {
        "trailList": [
            {
                "Name": "org-trail",
                "TrailARN": "arn:aws:cloudtrail:us-east-1:111111111111:trail/org-trail",
                "IsMultiRegionTrail": True,
                "LogFileValidationEnabled": True,
            }
        ]
    }
    cloudtrail.get_trail_status.return_value = {"IsLogging": True}

    metrics = collector._check_cloudtrail(cloudtrail, [])

    assert metrics == {
        "CloudTrailMultiRegionEnabled": 1,
        "CloudTrailLogFileValidationEnabled": 1,
        "CloudTrailLoggingActive": 1,
    }


def test_check_backups_counts_jobs_and_flags_no_plans():
    backup = MagicMock()
    backup.list_backup_plans.return_value = {"BackupPlansList": []}
    backup.get_paginator.return_value.paginate.return_value = [
        {
            "BackupJobs": [
                {"State": "COMPLETED", "ResourceArn": "arn:aws:ec2:...:instance/i-1"},
                {"State": "FAILED", "ResourceArn": "arn:aws:ec2:...:instance/i-2"},
                {"State": "RUNNING", "ResourceArn": "arn:aws:ec2:...:instance/i-3"},
            ]
        }
    ]

    findings = []
    metrics = collector._check_backups(backup, findings)

    assert metrics["BackupPlansCount"] == 0
    assert metrics["BackupJobsSucceeded24h"] == 1
    assert metrics["BackupJobsFailed24h"] == 1
    assert "NO_BACKUP_PLANS" in findings
    assert "BACKUP_JOB_FAILED resource=arn:aws:ec2:...:instance/i-2" in findings


def test_check_access_analyzer_no_active_analyzer():
    analyzer = MagicMock()
    analyzer.list_analyzers.return_value = {"analyzers": [{"status": "NOT_STARTED"}]}

    findings = []
    metrics = collector._check_access_analyzer(analyzer, findings)

    assert metrics == {"AccessAnalyzerActive": 0, "AccessAnalyzerExternalAccessFindings": 0}
    assert "NO_ACTIVE_ACCESS_ANALYZER" in findings


def test_check_access_analyzer_counts_active_findings():
    analyzer = MagicMock()
    analyzer.list_analyzers.return_value = {
        "analyzers": [{"status": "ACTIVE", "arn": "arn:aws:access-analyzer:...:analyzer/default"}]
    }
    analyzer.get_paginator.return_value.paginate.return_value = [
        {"findings": [{"resource": "arn:aws:s3:::my-bucket"}, {"resource": "arn:aws:iam::111111111111:role/x"}]}
    ]

    findings = []
    metrics = collector._check_access_analyzer(analyzer, findings)

    assert metrics["AccessAnalyzerActive"] == 1
    assert metrics["AccessAnalyzerExternalAccessFindings"] == 2


def test_check_high_availability_flags_single_az_and_non_multi_az():
    rds = MagicMock()
    rds.get_paginator.return_value.paginate.return_value = [
        {"DBInstances": [
            {"DBInstanceIdentifier": "db1", "MultiAZ": True},
            {"DBInstanceIdentifier": "db2", "MultiAZ": False},
        ]}
    ]
    autoscaling = MagicMock()
    autoscaling.get_paginator.return_value.paginate.return_value = [
        {"AutoScalingGroups": [
            {"AutoScalingGroupName": "asg1", "AvailabilityZones": ["us-east-1a", "us-east-1b"]},
            {"AutoScalingGroupName": "asg2", "AvailabilityZones": ["us-east-1a"]},
        ]}
    ]

    findings = []
    metrics = collector._check_high_availability(rds, autoscaling, findings)

    assert metrics == {"RdsInstancesNotMultiAz": 1, "AsgSingleAzCount": 1}
    assert "RDS_NOT_MULTI_AZ instance=db2" in findings
    assert "ASG_SINGLE_AZ name=asg2" in findings


def test_check_auto_remediation_counts_covered_and_uncovered_rules():
    config = MagicMock()
    config.describe_remediation_configurations.return_value = {
        "RemediationConfigurations": [{"ConfigRuleName": "rule-a"}]
    }

    findings = []
    metrics = collector._check_auto_remediation(config, ["rule-a", "rule-b"], findings)

    assert metrics == {"ConfigRulesWithRemediation": 1, "ConfigRulesWithoutRemediation": 1}
    assert "CONFIG_RULE_NO_REMEDIATION rule=rule-b" in findings


def test_check_auto_remediation_skips_api_call_when_nothing_non_compliant():
    config = MagicMock()

    metrics = collector._check_auto_remediation(config, [], [])

    assert metrics == {"ConfigRulesWithRemediation": 0, "ConfigRulesWithoutRemediation": 0}
    config.describe_remediation_configurations.assert_not_called()


def test_check_network_segmentation_flags_default_nacl_only_vpc():
    ec2 = MagicMock()
    ec2.describe_vpc_endpoints.return_value = {"VpcEndpoints": [{"VpcEndpointId": "vpce-1"}]}
    ec2.describe_vpcs.return_value = {"Vpcs": [{"VpcId": "vpc-1"}, {"VpcId": "vpc-2"}]}
    ec2.describe_network_acls.return_value = {
        "NetworkAcls": [
            {"VpcId": "vpc-1", "IsDefault": False},
            {"VpcId": "vpc-2", "IsDefault": True},
        ]
    }

    findings = []
    metrics = collector._check_network_segmentation(ec2, findings)

    assert metrics == {"VpcEndpointsCount": 1, "VpcsWithoutCustomNacl": 1}
    assert "VPC_DEFAULT_NACL_ONLY vpc=vpc-2" in findings


def test_check_acm_certificates_flags_expiring_cert():
    acm = MagicMock()
    acm.get_paginator.return_value.paginate.return_value = [
        {"CertificateSummaryList": [{"CertificateArn": "arn:cert1"}]}
    ]
    acm.describe_certificate.return_value = {
        "Certificate": {
            "NotAfter": datetime.now(timezone.utc) + timedelta(days=5),
            "DomainName": "example.com",
        }
    }

    findings = []
    metrics = collector._check_acm_certificates(acm, findings)

    assert metrics == {"AcmCertsExpiringSoon": 1}
    assert "ACM_CERT_EXPIRING domain=example.com" in findings


def test_check_s3_secure_transport_flags_open_bucket():
    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": [{"Name": "secure-bucket"}, {"Name": "open-bucket"}]}

    def get_bucket_policy(Bucket):
        if Bucket == "secure-bucket":
            return {
                "Policy": json.dumps({
                    "Statement": [
                        {"Effect": "Deny", "Condition": {"Bool": {"aws:SecureTransport": "false"}}}
                    ]
                })
            }
        raise ClientError({"Error": {"Code": "NoSuchBucketPolicy"}}, "GetBucketPolicy")

    s3.get_bucket_policy.side_effect = get_bucket_policy

    findings = []
    metrics = collector._check_s3_secure_transport(s3, findings)

    assert metrics == {"S3BucketsWithoutSecureTransportPolicy": 1}
    assert "S3_NO_SECURE_TRANSPORT_POLICY bucket=open-bucket" in findings


def test_check_security_hub_score_returns_raw_pass_fail_counts():
    securityhub = MagicMock()
    securityhub.get_paginator.return_value.paginate.return_value = [
        {"Findings": [
            {"Compliance": {"Status": "PASSED"}},
            {"Compliance": {"Status": "PASSED"}},
            {"Compliance": {"Status": "FAILED"}, "GeneratorId": "gen1"},
        ]}
    ]

    findings = []
    metrics = collector._check_security_hub_score(securityhub, findings)

    assert metrics == {"SecurityHubControlsPassed": 2, "SecurityHubControlsFailed": 1}
    assert "SECURITY_HUB_CONTROL_FAILED id=gen1" in findings


def test_check_security_hub_score_zero_when_nothing_evaluated():
    securityhub = MagicMock()
    securityhub.get_paginator.return_value.paginate.return_value = [{"Findings": []}]

    metrics = collector._check_security_hub_score(securityhub, [])

    assert metrics == {"SecurityHubControlsPassed": 0, "SecurityHubControlsFailed": 0}


def test_check_inspector_findings_counts_by_severity():
    inspector2 = MagicMock()
    inspector2.get_paginator.return_value.paginate.return_value = [
        {"findings": [
            {"severity": "CRITICAL", "findingArn": "a1"},
            {"severity": "HIGH", "findingArn": "a2"},
            {"severity": "HIGH", "findingArn": "a3"},
        ]}
    ]

    findings = []
    metrics = collector._check_inspector_findings(inspector2, findings)

    assert metrics == {"Inspector2CriticalFindings": 1, "Inspector2HighFindings": 2}


def test_check_non_user_auth_flags_instances_without_profile():
    ec2 = MagicMock()
    ec2.get_paginator.return_value.paginate.return_value = [
        {"Reservations": [
            {"Instances": [
                {"InstanceId": "i-1", "IamInstanceProfile": {"Arn": "arn:x"}},
                {"InstanceId": "i-2"},
            ]}
        ]}
    ]

    findings = []
    metrics = collector._check_non_user_auth(ec2, findings)

    assert metrics == {"Ec2InstancesWithoutInstanceProfile": 1}
    assert "EC2_NO_INSTANCE_PROFILE instance=i-2" in findings


def test_check_trusted_advisor_when_available():
    support = MagicMock()
    support.describe_trusted_advisor_checks.return_value = {
        "checks": [{"id": "c1", "category": "security", "name": "Check1"}]
    }
    support.describe_trusted_advisor_check_result.return_value = {"result": {"status": "warning"}}

    findings = []
    metrics = collector._check_trusted_advisor(support, findings)

    assert metrics == {"TrustedAdvisorAvailable": 1, "TrustedAdvisorSecurityChecksFlagged": 1}
    assert "TRUSTED_ADVISOR_FLAGGED check=Check1 status=warning" in findings


def test_check_trusted_advisor_when_unavailable_on_basic_support():
    support = MagicMock()
    support.describe_trusted_advisor_checks.side_effect = ClientError(
        {"Error": {"Code": "SubscriptionRequiredException"}}, "DescribeTrustedAdvisorChecks"
    )

    metrics = collector._check_trusted_advisor(support, [])

    assert metrics == {"TrustedAdvisorAvailable": 0, "TrustedAdvisorSecurityChecksFlagged": 0}


def test_check_detector_status_all_enabled():
    guardduty = MagicMock()
    guardduty.list_detectors.return_value = {"DetectorIds": ["det-1"]}
    guardduty.get_detector.return_value = {"Status": "ENABLED"}

    securityhub = MagicMock()
    securityhub.describe_hub.return_value = {"HubArn": "arn:x"}

    inspector2 = MagicMock()
    inspector2.batch_get_account_status.return_value = {
        "accounts": [{"resourceState": {"ec2": {"status": "ENABLED"}, "ecr": {"status": "DISABLED"}}}]
    }

    findings = []
    metrics = collector._check_detector_status(guardduty, securityhub, inspector2, findings)

    assert metrics == {"GuardDutyEnabled": 1, "SecurityHubEnabled": 1, "Inspector2Enabled": 1}
    assert findings == []


def test_check_detector_status_all_disabled():
    guardduty = MagicMock()
    guardduty.list_detectors.return_value = {"DetectorIds": []}

    securityhub = MagicMock()
    securityhub.describe_hub.side_effect = ClientError(
        {"Error": {"Code": "InvalidAccessException"}}, "DescribeHub"
    )

    inspector2 = MagicMock()
    inspector2.batch_get_account_status.return_value = {
        "accounts": [{"resourceState": {"ec2": {"status": "DISABLED"}}}]
    }

    findings = []
    metrics = collector._check_detector_status(guardduty, securityhub, inspector2, findings)

    assert metrics == {"GuardDutyEnabled": 0, "SecurityHubEnabled": 0, "Inspector2Enabled": 0}
    assert "GUARDDUTY_NOT_ENABLED" in findings
    assert "SECURITY_HUB_NOT_ENABLED" in findings
    assert "INSPECTOR2_NOT_ENABLED" in findings


def test_check_ebs_and_rds_encryption_all_compliant():
    ec2 = MagicMock()
    ec2.get_ebs_encryption_by_default.return_value = {"EbsEncryptionByDefault": True}

    rds = MagicMock()
    rds.get_paginator.return_value.paginate.return_value = [
        {"DBInstances": [
            {"DBInstanceIdentifier": "db1", "StorageEncrypted": True},
            {"DBInstanceIdentifier": "db2", "StorageEncrypted": False},
        ]}
    ]

    findings = []
    metrics = collector._check_ebs_and_rds_encryption(ec2, rds, findings)

    assert metrics == {"EbsEncryptionByDefaultEnabled": 1, "RdsInstancesUnencrypted": 1}
    assert "RDS_STORAGE_UNENCRYPTED instance=db2" in findings


def test_check_ebs_and_rds_encryption_disabled():
    ec2 = MagicMock()
    ec2.get_ebs_encryption_by_default.return_value = {"EbsEncryptionByDefault": False}

    rds = MagicMock()
    rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": []}]

    findings = []
    metrics = collector._check_ebs_and_rds_encryption(ec2, rds, findings)

    assert metrics == {"EbsEncryptionByDefaultEnabled": 0, "RdsInstancesUnencrypted": 0}
    assert "EBS_ENCRYPTION_BY_DEFAULT_DISABLED" in findings


def test_check_s3_account_public_access_enabled():
    s3control = MagicMock()
    s3control.get_public_access_block.return_value = {
        "PublicAccessBlockConfiguration": {
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        }
    }

    metrics = collector._check_s3_account_public_access(s3control, "111111111111", [])

    assert metrics == {"S3AccountBlockPublicAccessEnabled": 1}


def test_check_s3_account_public_access_not_configured():
    s3control = MagicMock()
    s3control.get_public_access_block.side_effect = ClientError(
        {"Error": {"Code": "NoSuchPublicAccessBlockConfiguration"}}, "GetPublicAccessBlock"
    )

    findings = []
    metrics = collector._check_s3_account_public_access(s3control, "111111111111", findings)

    assert metrics == {"S3AccountBlockPublicAccessEnabled": 0}
    assert "S3_ACCOUNT_BLOCK_PUBLIC_ACCESS_NOT_CONFIGURED" in findings


def test_check_password_policy_compliant():
    iam = MagicMock()
    iam.get_account_password_policy.return_value = {
        "PasswordPolicy": {
            "MinimumPasswordLength": 14,
            "RequireSymbols": True,
            "RequireNumbers": True,
            "RequireUppercaseCharacters": True,
            "RequireLowercaseCharacters": True,
            "MaxPasswordAge": 90,
            "PasswordReusePrevention": 24,
        }
    }

    metrics = collector._check_password_policy(iam, [])

    assert metrics == {"IamPasswordPolicyCompliant": 1}


def test_check_password_policy_weak():
    iam = MagicMock()
    iam.get_account_password_policy.return_value = {
        "PasswordPolicy": {
            "MinimumPasswordLength": 8,
            "RequireSymbols": False,
            "RequireNumbers": True,
            "RequireUppercaseCharacters": True,
            "RequireLowercaseCharacters": True,
        }
    }

    findings = []
    metrics = collector._check_password_policy(iam, findings)

    assert metrics == {"IamPasswordPolicyCompliant": 0}
    assert "IAM_PASSWORD_POLICY_WEAK" in findings


def test_check_password_policy_none_set():
    iam = MagicMock()
    iam.get_account_password_policy.side_effect = ClientError(
        {"Error": {"Code": "NoSuchEntity"}}, "GetAccountPasswordPolicy"
    )

    findings = []
    metrics = collector._check_password_policy(iam, findings)

    assert metrics == {"IamPasswordPolicyCompliant": 0}
    assert "NO_IAM_PASSWORD_POLICY" in findings


def test_enabled_regions_returns_sorted_names():
    ec2 = MagicMock()
    ec2.describe_regions.return_value = {
        "Regions": [{"RegionName": "us-west-2"}, {"RegionName": "us-east-1"}]
    }

    assert collector._enabled_regions(ec2) == ["us-east-1", "us-west-2"]


def test_enabled_regions_falls_back_when_describe_regions_fails():
    ec2 = MagicMock()
    ec2.describe_regions.side_effect = ClientError({"Error": {"Code": "AccessDenied"}}, "DescribeRegions")

    # boto3.session.Session().region_name is whatever the real boto3 session
    # reports; we only assert it falls back to a single-item list rather
    # than raising or returning an empty list.
    regions = collector._enabled_regions(ec2)
    assert len(regions) == 1


def test_merge_and():
    assert collector._merge_and(1, 1) == 1
    assert collector._merge_and(1, 0) == 0
    assert collector._merge_and(0, 1) == 0
    assert collector._merge_and(0, 0) == 0


def test_merge_or():
    assert collector._merge_or(0, 0) == 0
    assert collector._merge_or(0, 1) == 1
    assert collector._merge_or(1, 0) == 1
    assert collector._merge_or(1, 1) == 1


@patch("fedramp20x_collector.boto3.client")
def test_handler_aggregates_correctly_across_differing_regions(mock_client):
    """
    The real point of this test: us-east-1 and us-west-2 deliberately
    disagree with each other. If the aggregation logic in handler() were
    wrong -- summing when it should AND, or vice versa -- this is what
    would catch it. A single-region test can't, since AND/OR/SUM of one
    value all return that same value.
    """
    cw = MagicMock()

    def make_config(region):
        c = MagicMock()
        if region == "us-east-1":
            c.describe_configuration_recorders.return_value = {"ConfigurationRecorders": [{"name": "default"}]}
            c.describe_configuration_recorder_status.return_value = {"ConfigurationRecordersStatus": [{"recording": True}]}
            c.get_paginator.return_value.paginate.return_value = [{"ComplianceByConfigRules": []}]
        else:
            c.describe_configuration_recorders.return_value = {"ConfigurationRecorders": []}
            c.describe_configuration_recorder_status.return_value = {"ConfigurationRecordersStatus": []}
            c.get_paginator.return_value.paginate.return_value = [{"ComplianceByConfigRules": [
                {"ConfigRuleName": "r1", "Compliance": {"ComplianceType": "NON_COMPLIANT"}},
                {"ConfigRuleName": "r2", "Compliance": {"ComplianceType": "NON_COMPLIANT"}},
            ]}]
        c.describe_remediation_configurations.return_value = {"RemediationConfigurations": []}
        return c

    def make_cloudtrail(region):
        ct = MagicMock()
        if region == "us-west-2":
            ct.describe_trails.return_value = {"trailList": [{
                "Name": "org-trail", "TrailARN": "arn:x",
                "IsMultiRegionTrail": True, "LogFileValidationEnabled": True,
            }]}
            ct.get_trail_status.return_value = {"IsLogging": True}
        else:
            ct.describe_trails.return_value = {"trailList": []}
        return ct

    def make_guardduty(region):
        gd = MagicMock()
        if region == "us-east-1":
            gd.list_detectors.return_value = {"DetectorIds": ["d1"]}
            gd.get_detector.return_value = {"Status": "ENABLED"}
        else:
            gd.list_detectors.return_value = {"DetectorIds": []}
        return gd

    def empty_paginated(*keys):
        m = MagicMock()
        m.get_paginator.return_value.paginate.return_value = [{k: [] for k in keys}]
        return m

    def client_factory(service, *args, **kwargs):
        region = kwargs.get("region_name", "us-east-1")
        if service == "ec2" and "region_name" not in kwargs:
            m = MagicMock()
            m.describe_regions.return_value = {
                "Regions": [{"RegionName": "us-east-1"}, {"RegionName": "us-west-2"}]
            }
            return m
        if service == "config":
            return make_config(region)
        if service == "cloudtrail":
            return make_cloudtrail(region)
        if service == "backup":
            return empty_paginated("BackupJobs")
        if service == "accessanalyzer":
            m = MagicMock()
            m.list_analyzers.return_value = {"analyzers": []}
            return m
        if service == "rds":
            return empty_paginated("DBInstances")
        if service == "autoscaling":
            return empty_paginated("AutoScalingGroups")
        if service == "ec2":  # regional ec2 (region_name kwarg present)
            m = MagicMock()
            m.describe_vpc_endpoints.return_value = {"VpcEndpoints": []}
            m.describe_vpcs.return_value = {"Vpcs": []}
            m.describe_network_acls.return_value = {"NetworkAcls": []}
            m.get_paginator.return_value.paginate.return_value = [{"Reservations": []}]
            m.get_ebs_encryption_by_default.return_value = {"EbsEncryptionByDefault": region == "us-east-1"}
            return m
        if service == "acm":
            return empty_paginated("CertificateSummaryList")
        if service == "securityhub":
            return empty_paginated("Findings")
        if service == "inspector2":
            m = empty_paginated("findings")
            m.batch_get_account_status.return_value = {"accounts": [{"resourceState": {}}]}
            return m
        if service == "guardduty":
            return make_guardduty(region)
        if service == "support":
            m = MagicMock()
            m.describe_trusted_advisor_checks.return_value = {"checks": []}
            return m
        if service == "s3":
            m = MagicMock()
            m.list_buckets.return_value = {"Buckets": []}
            return m
        if service == "s3control":
            m = MagicMock()
            m.get_public_access_block.side_effect = ClientError(
                {"Error": {"Code": "NoSuchPublicAccessBlockConfiguration"}}, "GetPublicAccessBlock"
            )
            return m
        if service == "iam":
            m = MagicMock()
            m.get_account_password_policy.side_effect = ClientError(
                {"Error": {"Code": "NoSuchEntity"}}, "GetAccountPasswordPolicy"
            )
            return m
        if service == "sts":
            m = MagicMock()
            m.get_caller_identity.return_value = {"Account": "111111111111"}
            return m
        if service == "cloudwatch":
            return cw
        raise AssertionError(f"unexpected client requested: {service}")

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    published = {}
    for call in cw.put_metric_data.call_args_list:
        for item in call.kwargs["MetricData"]:
            published[item["MetricName"]] = item["Value"]
        assert call.kwargs["Namespace"] == "FedRAMP20xAudit"

    # AND across regions: us-west-2 has these off, so the account-wide
    # metric must be 0 even though us-east-1 has them on.
    assert published["ConfigRecorderEnabled"] == 0
    assert published["GuardDutyEnabled"] == 0
    assert published["EbsEncryptionByDefaultEnabled"] == 0

    # OR across regions: us-west-2 has a multi-region trail even though
    # us-east-1 has none -- the account-wide metric must be 1.
    assert published["CloudTrailMultiRegionEnabled"] == 1
    assert published["CloudTrailLogFileValidationEnabled"] == 1
    assert published["CloudTrailLoggingActive"] == 1

    # SUM across regions: only us-west-2 has 2 non-compliant rules.
    assert published["ConfigRulesNonCompliant"] == 2
    assert published["ConfigRulesWithoutRemediation"] == 2

    assert result["metrics_published"] == 35  # every metric this collector defines, all tranches
    assert result["findings"] > 0  # us-west-2's failures got recorded
