"""
Unit tests for fedramp20x_collector.py, with boto3.client mocked so no real
Config/CloudTrail/Backup/Access Analyzer/CloudWatch calls happen.
"""
from unittest.mock import MagicMock, patch

import fedramp20x_collector as collector


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

    cw = MagicMock()

    def client_factory(service, *args, **kwargs):
        return {
            "config": config,
            "cloudtrail": cloudtrail,
            "backup": backup,
            "accessanalyzer": analyzer,
            "cloudwatch": cw,
        }[service]

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    assert result["metrics_published"] == 11  # every metric this collector defines
    cw.put_metric_data.assert_called_once()
    call_kwargs = cw.put_metric_data.call_args.kwargs
    assert call_kwargs["Namespace"] == "FedRAMP20xAudit"
    assert len(call_kwargs["MetricData"]) == 11
