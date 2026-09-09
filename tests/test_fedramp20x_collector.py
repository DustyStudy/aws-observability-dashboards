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


def test_check_secure_communications_flags_expiring_cert_and_open_bucket():
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
    metrics = collector._check_secure_communications(acm, s3, findings)

    assert metrics == {"AcmCertsExpiringSoon": 1, "S3BucketsWithoutSecureTransportPolicy": 1}
    assert "ACM_CERT_EXPIRING domain=example.com" in findings
    assert "S3_NO_SECURE_TRANSPORT_POLICY bucket=open-bucket" in findings


def test_check_security_hub_score_computes_pass_percentage():
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

    assert metrics == {"SecurityHubStandardsScorePercent": 67, "SecurityHubControlsEvaluated": 3}
    assert "SECURITY_HUB_CONTROL_FAILED id=gen1" in findings


def test_check_security_hub_score_zero_when_nothing_evaluated():
    securityhub = MagicMock()
    securityhub.get_paginator.return_value.paginate.return_value = [{"Findings": []}]

    metrics = collector._check_security_hub_score(securityhub, [])

    assert metrics == {"SecurityHubStandardsScorePercent": 0, "SecurityHubControlsEvaluated": 0}


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


@patch("fedramp20x_collector.boto3.client")
def test_handler_publishes_all_metrics(mock_client):
    config = MagicMock()
    config.describe_configuration_recorders.return_value = {"ConfigurationRecorders": [{"name": "default"}]}
    config.describe_configuration_recorder_status.return_value = {
        "ConfigurationRecordersStatus": [{"recording": True}]
    }
    config.get_paginator.return_value.paginate.return_value = [{"ComplianceByConfigRules": []}]

    cloudtrail = MagicMock()
    cloudtrail.describe_trails.return_value = {"trailList": []}

    backup = MagicMock()
    backup.list_backup_plans.return_value = {"BackupPlansList": []}
    backup.get_paginator.return_value.paginate.return_value = []

    analyzer = MagicMock()
    analyzer.list_analyzers.return_value = {"analyzers": []}

    rds = MagicMock()
    rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": []}]

    autoscaling = MagicMock()
    autoscaling.get_paginator.return_value.paginate.return_value = [{"AutoScalingGroups": []}]

    ec2 = MagicMock()
    ec2.describe_vpc_endpoints.return_value = {"VpcEndpoints": []}
    ec2.describe_vpcs.return_value = {"Vpcs": []}
    ec2.describe_network_acls.return_value = {"NetworkAcls": []}
    ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": []}]

    acm = MagicMock()
    acm.get_paginator.return_value.paginate.return_value = [{"CertificateSummaryList": []}]

    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": []}

    securityhub = MagicMock()
    securityhub.get_paginator.return_value.paginate.return_value = [{"Findings": []}]

    inspector2 = MagicMock()
    inspector2.get_paginator.return_value.paginate.return_value = [{"findings": []}]

    support = MagicMock()
    support.describe_trusted_advisor_checks.return_value = {"checks": []}

    cw = MagicMock()

    def client_factory(service, *args, **kwargs):
        return {
            "config": config,
            "cloudtrail": cloudtrail,
            "backup": backup,
            "accessanalyzer": analyzer,
            "rds": rds,
            "autoscaling": autoscaling,
            "ec2": ec2,
            "acm": acm,
            "s3": s3,
            "securityhub": securityhub,
            "inspector2": inspector2,
            "support": support,
            "cloudwatch": cw,
        }[service]

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    assert result["metrics_published"] == 26  # every metric this collector defines, both tranches
    # 26 metrics > the chunk size of 20, so this spans two put_metric_data calls.
    assert cw.put_metric_data.call_count == 2
    total_published = sum(
        len(call.kwargs["MetricData"]) for call in cw.put_metric_data.call_args_list
    )
    assert total_published == 26
    for call in cw.put_metric_data.call_args_list:
        assert call.kwargs["Namespace"] == "FedRAMP20xAudit"
