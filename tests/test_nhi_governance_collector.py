"""
Unit tests for nhi_governance_collector.py.

These target the pure decision logic (date math, external-trust-policy
detection, credential-report scanning) with hand-built input rows — no
AWS calls, no mocking of boto3 needed for most of these, since the
functions under test take already-fetched data as arguments.
"""
from datetime import datetime, timedelta, timezone

import nhi_governance_collector as collector


# ---------------------------------------------------------------------
# _parse_date / _days_since
# ---------------------------------------------------------------------

def test_parse_date_valid_iso_string():
    dt = collector._parse_date("2026-01-15T10:00:00+00:00")
    assert dt.year == 2026
    assert dt.month == 1
    assert dt.day == 15


def test_parse_date_none_for_not_supported_sentinels():
    assert collector._parse_date("N/A") is None
    assert collector._parse_date("no_information") is None
    assert collector._parse_date("not_supported") is None
    assert collector._parse_date("") is None
    assert collector._parse_date(None) is None


def test_parse_date_none_for_garbage_input():
    assert collector._parse_date("not-a-date") is None


def test_days_since_none_input_returns_none():
    assert collector._days_since(None) is None


def test_days_since_computes_positive_age():
    ten_days_ago = datetime.now(timezone.utc) - timedelta(days=10)
    age = collector._days_since(ten_days_ago)
    # Allow +/-1 for test execution time drift.
    assert age in (9, 10, 11)


# ---------------------------------------------------------------------
# _has_external_trust
# ---------------------------------------------------------------------

def test_external_trust_wildcard_principal_is_flagged():
    trust_doc = {"Statement": [{"Principal": {"AWS": "*"}}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_same_account_arn_is_not_flagged():
    trust_doc = {
        "Statement": [
            {"Principal": {"AWS": "arn:aws:iam::111111111111:root"}}
        ]
    }
    assert collector._has_external_trust(trust_doc, "111111111111") is False


def test_external_trust_different_account_arn_is_flagged():
    trust_doc = {
        "Statement": [
            {"Principal": {"AWS": "arn:aws:iam::222222222222:root"}}
        ]
    }
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_service_principal_only_is_not_flagged():
    trust_doc = {"Statement": [{"Principal": {"Service": "lambda.amazonaws.com"}}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is False


def test_external_trust_handles_list_of_principals():
    trust_doc = {
        "Statement": [
            {
                "Principal": {
                    "AWS": [
                        "arn:aws:iam::111111111111:root",
                        "arn:aws:iam::999999999999:role/some-role",
                    ]
                }
            }
        ]
    }
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_malformed_json_does_not_raise():
    # Should degrade to "not external" rather than crash the scan.
    assert collector._has_external_trust("{not valid json", "111111111111") is False


# ---------------------------------------------------------------------
# _scan_credential_report
# ---------------------------------------------------------------------

def _base_row(**overrides):
    row = {
        "user": "alice",
        "password_enabled": "false",
        "mfa_active": "false",
        "access_key_1_active": "false",
        "access_key_2_active": "false",
        "access_key_1_last_rotated": "N/A",
        "access_key_1_last_used_date": "N/A",
        "access_key_2_last_rotated": "N/A",
        "access_key_2_last_used_date": "N/A",
        "password_last_used": "N/A",
        "user_creation_time": "N/A",
    }
    row.update(overrides)
    return row


def test_scan_credential_report_skips_root_account():
    rows = [_base_row(user="<root_account>", password_enabled="true", mfa_active="false")]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["UsersWithoutMfa"] == 0
    assert findings == []


def test_scan_credential_report_flags_console_user_without_mfa():
    rows = [_base_row(password_enabled="true", mfa_active="false")]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["UsersWithoutMfa"] == 1
    assert any("NO_MFA user=alice" in f for f in findings)


def test_scan_credential_report_does_not_flag_user_with_mfa():
    rows = [_base_row(password_enabled="true", mfa_active="true")]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["UsersWithoutMfa"] == 0


def test_scan_credential_report_flags_stale_access_key():
    stale_date = (datetime.now(timezone.utc) - timedelta(days=200)).isoformat()
    rows = [
        _base_row(
            access_key_1_active="true",
            access_key_1_last_rotated=stale_date,
        )
    ]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["StaleAccessKeys"] == 1
    assert metrics["TotalActiveAccessKeys"] == 1
    assert any("STALE_ACCESS_KEY user=alice key_slot=1" in f for f in findings)


def test_scan_credential_report_does_not_flag_recently_rotated_key():
    fresh_date = (datetime.now(timezone.utc) - timedelta(days=5)).isoformat()
    rows = [
        _base_row(
            access_key_1_active="true",
            access_key_1_last_rotated=fresh_date,
        )
    ]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["StaleAccessKeys"] == 0
    assert metrics["TotalActiveAccessKeys"] == 1


def test_scan_credential_report_flags_inactive_user():
    old_creation = (datetime.now(timezone.utc) - timedelta(days=400)).isoformat()
    rows = [_base_row(user_creation_time=old_creation)]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["InactiveIamUsers"] == 1
    assert any("INACTIVE_USER user=alice" in f for f in findings)


def test_scan_credential_report_recent_key_use_prevents_inactive_flag():
    old_creation = (datetime.now(timezone.utc) - timedelta(days=400)).isoformat()
    recent_use = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    rows = [
        _base_row(
            user_creation_time=old_creation,
            access_key_1_active="true",
            access_key_1_last_used_date=recent_use,
        )
    ]
    findings = []
    metrics = collector._scan_credential_report(rows, findings)
    assert metrics["InactiveIamUsers"] == 0


# ---------------------------------------------------------------------
# chunked
# ---------------------------------------------------------------------

def test_chunked_splits_into_expected_batch_sizes():
    items = list(range(45))
    batches = list(collector.chunked(items, 20))
    assert [len(b) for b in batches] == [20, 20, 5]
    assert sum(batches, []) == items


def test_chunked_empty_input_yields_no_batches():
    assert list(collector.chunked([], 20)) == []


# ---------------------------------------------------------------------
# _has_external_trust: forms that used to be missed or to crash the scan
# ---------------------------------------------------------------------

def test_external_trust_string_wildcard_principal_is_flagged():
    # "Principal": "*" is the string form of {"AWS": "*"}: publicly assumable.
    trust_doc = {"Statement": [{"Effect": "Allow", "Principal": "*"}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_single_statement_object_does_not_crash():
    # IAM accepts "Statement": {...} instead of a list. Iterating the dict used
    # to raise AttributeError and take the whole NHI scan down with it.
    trust_doc = {"Statement": {"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::222222222222:root"}}}
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_bare_account_id_other_account_is_flagged():
    trust_doc = {"Statement": [{"Effect": "Allow", "Principal": {"AWS": "222222222222"}}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_bare_account_id_same_account_is_not_flagged():
    trust_doc = {"Statement": [{"Effect": "Allow", "Principal": {"AWS": "111111111111"}}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is False


def test_external_trust_own_account_id_inside_foreign_role_name_is_still_flagged():
    # The old substring check treated this as internal because the role name
    # happens to contain our account ID.
    trust_doc = {
        "Statement": [
            {"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::999999999999:role/x-111111111111"}}
        ]
    }
    assert collector._has_external_trust(trust_doc, "111111111111") is True


def test_external_trust_deny_statement_is_not_a_grant():
    trust_doc = {"Statement": [{"Effect": "Deny", "Principal": {"AWS": "*"}}]}
    assert collector._has_external_trust(trust_doc, "111111111111") is False


def test_external_trust_non_object_document_does_not_raise():
    assert collector._has_external_trust("[1, 2, 3]", "111111111111") is False


# ---------------------------------------------------------------------
# _scan_roles: last-used comes from get_role, not list_roles
# ---------------------------------------------------------------------

def _iam_with_roles(roles, get_role_side_effect):
    from unittest.mock import MagicMock

    iam = MagicMock()
    iam.get_paginator.return_value.paginate.return_value = [{"Roles": roles}]
    iam.get_role.side_effect = get_role_side_effect
    return iam


def _role(name):
    return {"RoleName": name, "Path": "/", "AssumeRolePolicyDocument": {"Statement": []}}


def test_scan_roles_uses_get_role_last_used_so_recent_roles_are_not_stale():
    recent = datetime.now(timezone.utc) - timedelta(days=5)
    iam = _iam_with_roles(
        [_role("active")],
        lambda RoleName: {"Role": {"RoleLastUsed": {"LastUsedDate": recent}}},
    )
    findings = []
    result = collector._scan_roles(iam, "111111111111", findings)
    assert result["TotalIamRoles"] == 1
    assert result["StaleIamRoles"] == 0
    assert findings == []


def test_scan_roles_flags_old_and_never_used_roles():
    old = datetime.now(timezone.utc) - timedelta(days=400)
    details = {
        "old": {"Role": {"RoleLastUsed": {"LastUsedDate": old}}},
        "never": {"Role": {"RoleLastUsed": {}}},
    }
    iam = _iam_with_roles([_role("old"), _role("never")], lambda RoleName: details[RoleName])
    findings = []
    result = collector._scan_roles(iam, "111111111111", findings)
    assert result["StaleIamRoles"] == 2
    assert any("role=never reason=never_used" in f for f in findings)
    assert any("role=old" in f and "age_days=" in f for f in findings)


def test_scan_roles_does_not_guess_stale_when_get_role_fails():
    from botocore.exceptions import ClientError

    def boom(RoleName):
        raise ClientError({"Error": {"Code": "Throttling", "Message": "slow down"}}, "GetRole")

    iam = _iam_with_roles([_role("unknown")], boom)
    findings = []
    result = collector._scan_roles(iam, "111111111111", findings)
    assert result["TotalIamRoles"] == 1
    assert result["StaleIamRoles"] == 0
    assert findings == []
