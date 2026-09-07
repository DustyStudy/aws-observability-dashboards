"""
Unit tests for bedrock_cost_collector.py, with boto3.client mocked so no
real Cost Explorer or CloudWatch calls happen.
"""
from unittest.mock import MagicMock, patch

import bedrock_cost_collector as collector


@patch("bedrock_cost_collector.boto3.client")
def test_handler_sums_usage_types_into_total(mock_client):
    ce = MagicMock()
    ce.get_cost_and_usage.return_value = {
        "ResultsByTime": [
            {
                "Groups": [
                    {
                        "Keys": ["Bedrock-Inference-Input-Tokens"],
                        "Metrics": {"UnblendedCost": {"Amount": "1.50"}},
                    },
                    {
                        "Keys": ["Bedrock-Inference-Output-Tokens"],
                        "Metrics": {"UnblendedCost": {"Amount": "3.25"}},
                    },
                ]
            }
        ]
    }
    cw = MagicMock()

    def client_factory(service, region_name=None):
        return {"ce": ce, "cloudwatch": cw}[service]

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    assert result["total_cost_usd"] == 4.75
    # One metric per usage type plus one TOTAL metric.
    assert result["published_metrics"] == 3
    cw.put_metric_data.assert_called_once()
    published = cw.put_metric_data.call_args.kwargs["MetricData"]
    total_entries = [m for m in published if m["Dimensions"][0]["Value"] == "TOTAL"]
    assert len(total_entries) == 1
    assert total_entries[0]["Value"] == 4.75


@patch("bedrock_cost_collector.boto3.client")
def test_handler_uses_us_east_1_for_cost_explorer_regardless_of_runtime_region(mock_client):
    ce = MagicMock()
    ce.get_cost_and_usage.return_value = {"ResultsByTime": []}
    cw = MagicMock()

    calls = []

    def client_factory(service, region_name=None):
        calls.append((service, region_name))
        return {"ce": ce, "cloudwatch": cw}[service]

    mock_client.side_effect = client_factory

    collector.handler({}, None)

    assert ("ce", "us-east-1") in calls


@patch("bedrock_cost_collector.boto3.client")
def test_handler_no_usage_still_publishes_zero_total(mock_client):
    ce = MagicMock()
    ce.get_cost_and_usage.return_value = {"ResultsByTime": [{"Groups": []}]}
    cw = MagicMock()

    def client_factory(service, region_name=None):
        return {"ce": ce, "cloudwatch": cw}[service]

    mock_client.side_effect = client_factory

    result = collector.handler({}, None)

    assert result["total_cost_usd"] == 0.0
    assert result["published_metrics"] == 1  # just the TOTAL entry
    cw.put_metric_data.assert_called_once()
