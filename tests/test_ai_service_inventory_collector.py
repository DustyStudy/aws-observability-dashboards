"""
Unit tests for ai_service_inventory_collector.py, with boto3.client mocked
so no real EC2/CloudWatch calls happen.
"""
from unittest.mock import MagicMock, patch

import ai_service_inventory_collector as collector


def test_chunked_basic():
    assert list(collector.chunked([1, 2, 3, 4, 5], 3)) == [[1, 2, 3], [4, 5]]


@patch("ai_service_inventory_collector.boto3.client")
def test_handler_marks_service_active_when_metrics_exist(mock_client):
    ec2 = MagicMock()
    ec2.describe_regions.return_value = {"Regions": [{"RegionName": "us-east-1"}]}

    region_cw = MagicMock()
    region_cw.list_metrics.return_value = {"Metrics": [{"MetricName": "Invocations"}]}

    home_cw = MagicMock()

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        if service == "cloudwatch" and region_name == "us-east-1":
            return region_cw
        if service == "cloudwatch" and region_name is None:
            return home_cw
        return MagicMock()

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    assert result["regions_checked"] == 1
    # One ServiceActive metric per entry in SERVICES for the one region.
    assert result["metrics_published"] == len(collector.SERVICES)
    home_cw.put_metric_data.assert_called_once()
    published = home_cw.put_metric_data.call_args.kwargs["MetricData"]
    assert all(m["Value"] == 1 for m in published)


@patch("ai_service_inventory_collector.boto3.client")
def test_handler_marks_service_inactive_when_no_metrics(mock_client):
    ec2 = MagicMock()
    ec2.describe_regions.return_value = {"Regions": [{"RegionName": "us-east-1"}]}

    region_cw = MagicMock()
    region_cw.list_metrics.return_value = {"Metrics": []}

    home_cw = MagicMock()

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        if service == "cloudwatch" and region_name == "us-east-1":
            return region_cw
        return home_cw

    mock_client.side_effect = client_factory

    collector.handler({}, None)

    published = home_cw.put_metric_data.call_args.kwargs["MetricData"]
    assert all(m["Value"] == 0 for m in published)


@patch("ai_service_inventory_collector.boto3.client")
def test_handler_treats_namespace_error_as_inactive_not_a_crash(mock_client):
    ec2 = MagicMock()
    ec2.describe_regions.return_value = {"Regions": [{"RegionName": "ap-southeast-3"}]}

    region_cw = MagicMock()
    region_cw.list_metrics.side_effect = Exception("opt-in region, service unavailable")

    home_cw = MagicMock()

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        if service == "cloudwatch" and region_name == "ap-southeast-3":
            return region_cw
        return home_cw

    mock_client.side_effect = client_factory

    # Should not raise, and every service should come back inactive for
    # that region rather than aborting the whole scan.
    result = collector.handler({}, None)
    published = home_cw.put_metric_data.call_args.kwargs["MetricData"]
    assert all(m["Value"] == 0 for m in published)
    assert result["metrics_published"] == len(collector.SERVICES)
