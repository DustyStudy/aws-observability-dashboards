"""
Unit tests for network_exposure_collector.py.

_is_open_rule / _rule_ports / chunked are pure and tested directly.
scan_region and scan_s3_buckets are tested with mocked boto3 clients so
no real AWS calls happen.
"""
from unittest.mock import MagicMock, patch

import network_exposure_collector as collector


# ---------------------------------------------------------------------
# _is_open_rule
# ---------------------------------------------------------------------

def test_is_open_rule_flags_ipv4_anywhere():
    perm = {"IpRanges": [{"CidrIp": "0.0.0.0/0"}]}
    assert collector._is_open_rule(perm) is True


def test_is_open_rule_flags_ipv6_anywhere():
    perm = {"Ipv6Ranges": [{"CidrIpv6": "::/0"}]}
    assert collector._is_open_rule(perm) is True


def test_is_open_rule_does_not_flag_restricted_cidr():
    perm = {"IpRanges": [{"CidrIp": "10.0.0.0/16"}]}
    assert collector._is_open_rule(perm) is False


def test_is_open_rule_handles_no_ranges():
    assert collector._is_open_rule({}) is False


# ---------------------------------------------------------------------
# _rule_ports
# ---------------------------------------------------------------------

def test_rule_ports_normal_range():
    perm = {"FromPort": 20, "ToPort": 22}
    assert collector._rule_ports(perm) == {20, 21, 22}


def test_rule_ports_single_port():
    perm = {"FromPort": 3389, "ToPort": 3389}
    assert collector._rule_ports(perm) == {3389}


def test_rule_ports_all_traffic_rule_covers_sensitive_ports():
    # A rule with no FromPort/ToPort (e.g. protocol "-1") covers everything,
    # so it must intersect with SENSITIVE_PORTS.
    perm = {}
    ports = collector._rule_ports(perm)
    assert collector.SENSITIVE_PORTS.issubset(ports)


# ---------------------------------------------------------------------
# chunked
# ---------------------------------------------------------------------

def test_chunked_basic():
    assert list(collector.chunked([1, 2, 3, 4, 5], 2)) == [[1, 2], [3, 4], [5]]


# ---------------------------------------------------------------------
# scan_region (mocked ec2/rds/elbv2 clients)
# ---------------------------------------------------------------------

def _paginated(pages):
    """Build a paginator mock whose .paginate() yields the given pages."""
    paginator = MagicMock()
    paginator.paginate.return_value = pages
    return paginator


@patch("network_exposure_collector.boto3.client")
def test_scan_region_flags_open_sensitive_security_group(mock_client):
    ec2 = MagicMock()
    ec2.get_paginator.side_effect = lambda name: {
        "describe_security_groups": _paginated([
            {
                "SecurityGroups": [
                    {
                        "GroupId": "sg-123",
                        "GroupName": "wide-open-ssh",
                        "IpPermissions": [
                            {
                                "FromPort": 22,
                                "ToPort": 22,
                                "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                            }
                        ],
                    }
                ]
            }
        ]),
        "describe_instances": _paginated([{"Reservations": []}]),
    }[name]

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        return MagicMock()

    mock_client.side_effect = client_factory

    findings = []
    result = collector.scan_region("us-east-1", findings)

    assert result["OpenSecurityGroupRules"] == 1
    assert result["OpenSensitivePortRules"] == 1
    assert any("OPEN_SENSITIVE_SG" in f and "sg-123" in f for f in findings)


@patch("network_exposure_collector.boto3.client")
def test_scan_region_open_rule_on_non_sensitive_port_not_double_counted(mock_client):
    ec2 = MagicMock()
    ec2.get_paginator.side_effect = lambda name: {
        "describe_security_groups": _paginated([
            {
                "SecurityGroups": [
                    {
                        "GroupId": "sg-456",
                        "GroupName": "open-http",
                        "IpPermissions": [
                            {
                                "FromPort": 80,
                                "ToPort": 80,
                                "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                            }
                        ],
                    }
                ]
            }
        ]),
        "describe_instances": _paginated([{"Reservations": []}]),
    }[name]

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        return MagicMock()

    mock_client.side_effect = client_factory

    findings = []
    result = collector.scan_region("us-east-1", findings)

    assert result["OpenSecurityGroupRules"] == 1
    assert result["OpenSensitivePortRules"] == 0
    assert findings == []


@patch("network_exposure_collector.boto3.client")
def test_scan_region_flags_public_ec2_instance(mock_client):
    ec2 = MagicMock()
    ec2.get_paginator.side_effect = lambda name: {
        "describe_security_groups": _paginated([{"SecurityGroups": []}]),
        "describe_instances": _paginated([
            {
                "Reservations": [
                    {
                        "Instances": [
                            {"InstanceId": "i-abc", "PublicIpAddress": "1.2.3.4"}
                        ]
                    }
                ]
            }
        ]),
    }[name]

    def client_factory(service, region_name=None):
        if service == "ec2":
            return ec2
        return MagicMock()

    mock_client.side_effect = client_factory

    findings = []
    result = collector.scan_region("us-east-1", findings)

    assert result["PublicEc2Instances"] == 1
    assert any("PUBLIC_EC2" in f and "i-abc" in f for f in findings)


@patch("network_exposure_collector.boto3.client")
def test_scan_region_rds_error_is_swallowed_not_raised(mock_client):
    from botocore.exceptions import ClientError

    ec2 = MagicMock()
    ec2.get_paginator.side_effect = lambda name: {
        "describe_security_groups": _paginated([{"SecurityGroups": []}]),
        "describe_instances": _paginated([{"Reservations": []}]),
    }[name]

    rds = MagicMock()
    rds.get_paginator.side_effect = ClientError(
        {"Error": {"Code": "AccessDenied", "Message": "nope"}}, "DescribeDBInstances"
    )

    def client_factory(service, region_name=None):
        return {"ec2": ec2, "rds": rds}.get(service, MagicMock())

    mock_client.side_effect = client_factory

    findings = []
    # Should not raise, and should report zero public RDS rather than crash
    # the whole region scan over one service's permissions problem.
    result = collector.scan_region("us-east-1", findings)
    assert result["PubliclyAccessibleRdsInstances"] == 0


# ---------------------------------------------------------------------
# scan_s3_buckets
# ---------------------------------------------------------------------

@patch("network_exposure_collector.boto3.client")
def test_scan_s3_buckets_flags_bucket_public_via_policy_status(mock_client):
    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": [{"Name": "my-public-bucket"}]}
    s3.get_bucket_location.return_value = {"LocationConstraint": "us-west-2"}
    s3.get_bucket_policy_status.return_value = {"PolicyStatus": {"IsPublic": True}}
    mock_client.return_value = s3

    findings = []
    region_counts = collector.scan_s3_buckets(findings)

    assert region_counts == {"us-west-2": 1}
    assert any("PUBLIC_S3 bucket=my-public-bucket" in f for f in findings)


@patch("network_exposure_collector.boto3.client")
def test_scan_s3_buckets_empty_location_constraint_means_us_east_1(mock_client):
    # AWS returns an empty LocationConstraint for us-east-1 buckets — this
    # is documented AWS behavior, not a bug, and must map to "us-east-1".
    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": [{"Name": "bucket-in-use1"}]}
    s3.get_bucket_location.return_value = {"LocationConstraint": None}
    s3.get_bucket_policy_status.return_value = {"PolicyStatus": {"IsPublic": True}}
    mock_client.return_value = s3

    findings = []
    region_counts = collector.scan_s3_buckets(findings)

    assert region_counts == {"us-east-1": 1}


@patch("network_exposure_collector.boto3.client")
def test_scan_s3_buckets_private_bucket_not_flagged(mock_client):
    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": [{"Name": "private-bucket"}]}
    s3.get_bucket_location.return_value = {"LocationConstraint": "us-west-2"}
    s3.get_bucket_policy_status.return_value = {"PolicyStatus": {"IsPublic": False}}
    s3.get_bucket_acl.return_value = {"Grants": []}
    mock_client.return_value = s3

    findings = []
    region_counts = collector.scan_s3_buckets(findings)

    assert region_counts == {}
    assert findings == []


@patch("network_exposure_collector.boto3.client")
def test_scan_s3_buckets_flags_bucket_public_via_acl_grant(mock_client):
    s3 = MagicMock()
    s3.list_buckets.return_value = {"Buckets": [{"Name": "acl-public-bucket"}]}
    s3.get_bucket_location.return_value = {"LocationConstraint": "eu-west-1"}
    s3.get_bucket_policy_status.return_value = {"PolicyStatus": {"IsPublic": False}}
    s3.get_bucket_acl.return_value = {
        "Grants": [
            {"Grantee": {"URI": "http://acs.amazonaws.com/groups/global/AllUsers"}}
        ]
    }
    mock_client.return_value = s3

    findings = []
    region_counts = collector.scan_s3_buckets(findings)

    assert region_counts == {"eu-west-1": 1}
