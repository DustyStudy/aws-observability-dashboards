"""
Unit tests for eks_patch_drift_checker.py.

The `eks` and `cloudwatch` clients are created inside lambda_handler (not
at module import time — see the comment in that function for why), so
tests patch boto3.client with a factory, same pattern as the other four
collectors' tests.
"""
import datetime
from unittest.mock import MagicMock, patch

import eks_patch_drift_checker as checker


def _client_factory(eks_mock, cw_mock):
    def factory(service, region_name=None):
        return {"eks": eks_mock, "cloudwatch": cw_mock}[service]
    return factory


@patch("eks_patch_drift_checker.boto3.client")
def test_version_drift_detected_against_latest_version(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["old-cluster"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.28",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": []}

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["clusterVersionDriftCount"] == 1


@patch("eks_patch_drift_checker.boto3.client")
def test_no_drift_when_cluster_matches_latest_version(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["current-cluster"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": []}

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["clusterVersionDriftCount"] == 0


@patch("eks_patch_drift_checker.boto3.client")
def test_public_only_endpoint_cluster_is_counted(mock_client):
    # Regression test: a Terraform/CFN drift bug previously had this counter
    # (mis-)named "unencrypted_or_public_clusters" even though it has
    # nothing to do with encryption — it's purely "public endpoint enabled,
    # private endpoint disabled". This locks in the correct behavior and
    # the corrected name so the two IaC implementations can't drift again
    # without a test failing.
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["public-cluster"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": True,
                "endpointPrivateAccess": False,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": []}

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["publicOnlyEndpointClusters"] == 1


@patch("eks_patch_drift_checker.boto3.client")
def test_dual_endpoint_cluster_not_counted_as_public_only(mock_client):
    # Both public and private access enabled — not "public-only" — must
    # not be flagged.
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["dual-access-cluster"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": True,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": []}

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["publicOnlyEndpointClusters"] == 0


@patch("eks_patch_drift_checker.boto3.client")
def test_stale_ami_nodegroup_detected(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["c1"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": ["ng-1"]}

    old_date = (datetime.datetime.utcnow() - datetime.timedelta(days=120)).strftime("%Y%m%d")
    mock_eks.describe_nodegroup.return_value = {
        "nodegroup": {
            "version": "1.31",
            "health": {"issues": []},
            "releaseVersion": f"1.31.0-{old_date}",
        }
    }

    with patch.object(checker, "LATEST_VERSION", "1.31"), patch.object(
        checker, "STALE_AMI_DAYS", 60
    ):
        result = checker.lambda_handler({}, None)

    assert result["body"]["staleAmiNodegroups"] == 1


@patch("eks_patch_drift_checker.boto3.client")
def test_recent_ami_nodegroup_not_flagged_stale(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["c1"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": ["ng-1"]}

    recent_date = (datetime.datetime.utcnow() - datetime.timedelta(days=5)).strftime("%Y%m%d")
    mock_eks.describe_nodegroup.return_value = {
        "nodegroup": {
            "version": "1.31",
            "health": {"issues": []},
            "releaseVersion": f"1.31.0-{recent_date}",
        }
    }

    with patch.object(checker, "LATEST_VERSION", "1.31"), patch.object(
        checker, "STALE_AMI_DAYS", 60
    ):
        result = checker.lambda_handler({}, None)

    assert result["body"]["staleAmiNodegroups"] == 0


@patch("eks_patch_drift_checker.boto3.client")
def test_malformed_release_version_does_not_raise(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["c1"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": ["ng-custom-ami"]}
    mock_eks.describe_nodegroup.return_value = {
        "nodegroup": {
            "version": "1.31",
            "health": {"issues": []},
            "releaseVersion": "custom-built-ami-no-date",
        }
    }

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["staleAmiNodegroups"] == 0


@patch("eks_patch_drift_checker.boto3.client")
def test_nodegroup_health_issues_are_counted(mock_client):
    mock_eks = MagicMock()
    mock_cw = MagicMock()
    mock_client.side_effect = _client_factory(mock_eks, mock_cw)

    mock_eks.list_clusters.return_value = {"clusters": ["c1"]}
    mock_eks.describe_cluster.return_value = {
        "cluster": {
            "version": "1.31",
            "resourcesVpcConfig": {
                "endpointPublicAccess": False,
                "endpointPrivateAccess": True,
            },
        }
    }
    mock_eks.list_nodegroups.return_value = {"nodegroups": ["ng-1"]}
    mock_eks.describe_nodegroup.return_value = {
        "nodegroup": {
            "version": "1.31",
            "health": {"issues": [{"code": "AsgInstanceLaunchFailures"}, {"code": "NodeCreationFailure"}]},
            "releaseVersion": "",
        }
    }

    with patch.object(checker, "LATEST_VERSION", "1.31"):
        result = checker.lambda_handler({}, None)

    assert result["body"]["nodegroupHealthIssues"] == 2
