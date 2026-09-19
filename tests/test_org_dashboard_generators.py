"""
Structural tests for the org-dashboard generator Lambdas.

Each cloudformation/<dashboard>/org-dashboard.yaml embeds a Lambda-backed
custom resource that renders a CloudWatch DashboardBody. These tests load
that inline code, drive its handler() the way CloudFormation would, and
check the dashboard it would submit: valid JSON, unique metric ids per
widget, widgets inside the 24-column grid without overlapping, CloudWatch's
size limits, both account modes, and input validation. They cannot prove a
query renders in a real monitoring account -- only that the generated
dashboard is well formed.
"""
import functools
import json
import types
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

MAX_WIDGETS = 500
MAX_METRICS_PER_WIDGET = 500
GRID_COLUMNS = 24

ACCOUNTS = ["111111111111", "222222222222", "333333333333"]
LOG_ACCOUNTS = ["444444444444", "555555555555"]

# Custom-resource properties (besides the account lists) each dashboard's
# handler reads, using values that are valid for it.
BASE_PROPS = {
    "nhi-governance": {"MetricNamespace": "NHIGovernance"},
    "agentic-ai-guardrails": {},
    "fedramp-20x-audit": {
        "MetricNamespace": "FedRAMP20xAudit",
        "NhiGovernanceNamespace": "NHIGovernance",
        "NetworkExposureNamespace": "NetworkExposure",
        "SecurityObservabilityNamespace": "SecurityObservability",
    },
    "bedrock-usage-cost": {"MetricNamespace": "BedrockUsageCost"},
    "ai-service-inventory": {"MetricNamespace": "AIServiceInventory"},
    "security-posture": {"MetricNamespace": "SecurityObservability", "NamePrefix": "security-posture"},
    "network-exposure": {"MetricNamespace": "NetworkExposure", "FlowLogsLogGroupName": "vpc-flow-logs"},
    "eks-security": {"MetricNamespace": "EKS/Security", "CollectorDashboardName": "eks-security"},
}
DASHBOARDS = sorted(BASE_PROPS)
HAS_LOG_ACCOUNTS = {"security-posture", "network-exposure", "eks-security"}
NAMESPACE_PROPS = {
    d: [k for k in p if k.endswith("Namespace")] for d, p in BASE_PROPS.items()
}


class _CfnLoader(yaml.SafeLoader):
    """Loads CloudFormation YAML, treating !Ref/!Sub/etc. as plain values."""


def _construct(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


_CfnLoader.add_multi_constructor("!", _construct)


@functools.lru_cache(maxsize=None)
def _load_generator(dashboard):
    path = REPO_ROOT / "cloudformation" / f"{dashboard}-dashboard" / "org-dashboard.yaml"
    template = yaml.load(path.read_text(encoding="utf-8"), Loader=_CfnLoader)
    code = next(
        r["Properties"]["Code"]["ZipFile"]
        for r in template["Resources"].values()
        if r["Type"] == "AWS::Lambda::Function"
    )
    namespace = {}
    exec(compile(code, str(path), "exec"), namespace)
    return namespace


def _run(dashboard, members="", log_accounts="", request_type="Create", **overrides):
    """Drive the generator's handler(); return (status, reason, put_dashboard bodies)."""
    # The generator is stateless: handler() looks up cloudwatch and
    # send_cfn_response in module globals on every call, so one loaded copy
    # per dashboard can be reused with fresh fakes swapped in.
    ns = _load_generator(dashboard)
    puts, responses, deleted = [], [], []
    ns["cloudwatch"] = types.SimpleNamespace(
        put_dashboard=lambda **kw: puts.append(kw),
        delete_dashboards=lambda **kw: deleted.append(kw),
    )
    ns["send_cfn_response"] = lambda event, context, status, **kw: responses.append(
        (status, kw.get("reason"))
    )
    props = {"DashboardName": "test-dashboard", "MemberAccountIds": members, "Region": "us-east-1"}
    props.update(BASE_PROPS[dashboard])
    if dashboard in HAS_LOG_ACCOUNTS:
        props["LogAccountIds"] = log_accounts
    props.update(overrides)
    event = {
        "RequestType": request_type,
        "ResourceProperties": props,
        "PhysicalResourceId": "test-dashboard",
        "StackId": "stack",
        "RequestId": "request",
        "LogicalResourceId": "OrgDashboard",
    }
    context = types.SimpleNamespace(
        invoked_function_arn="arn:aws:lambda:us-east-1:123456789012:function:generator",
        log_stream_name="stream",
    )
    ns["handler"](event, context)
    assert len(responses) == 1, "handler must send exactly one CloudFormation response"
    body = json.loads(puts[0]["DashboardBody"]) if puts else None
    return responses[0][0], responses[0][1], body, deleted


def _metric_ids(widget):
    return [
        entry["id"]
        for row in widget.get("properties", {}).get("metrics", [])
        for entry in row
        if isinstance(entry, dict) and "id" in entry
    ]


def _overlaps(a, b):
    return (
        a["x"] < b["x"] + b["width"]
        and b["x"] < a["x"] + a["width"]
        and a["y"] < b["y"] + b["height"]
        and b["y"] < a["y"] + a["height"]
    )


def _assert_well_formed(body):
    widgets = body["widgets"]
    assert 0 < len(widgets) <= MAX_WIDGETS
    for w in widgets:
        title = w.get("properties", {}).get("title", w.get("type"))
        assert w["x"] >= 0 and w["x"] + w["width"] <= GRID_COLUMNS, f"{title!r} leaves the grid"
        ids = _metric_ids(w)
        assert len(ids) == len(set(ids)), f"{title!r} has duplicate metric ids: {ids}"
        assert len(w.get("properties", {}).get("metrics", [])) <= MAX_METRICS_PER_WIDGET, title
    for i, a in enumerate(widgets):
        for b in widgets[i + 1:]:
            assert not _overlaps(a, b), (
                f"widgets overlap: {a.get('properties', {}).get('title')!r} / "
                f"{b.get('properties', {}).get('title')!r}"
            )


def _metric_entries(body):
    for w in body["widgets"]:
        if w.get("type") != "metric":
            continue
        for row in w["properties"].get("metrics", []):
            for entry in row:
                if isinstance(entry, dict):
                    yield entry


# ---------------------------------------------------------------------
# Well-formedness in every mode
# ---------------------------------------------------------------------

@pytest.mark.parametrize("dashboard", DASHBOARDS)
def test_explicit_mode_is_well_formed_and_uses_each_account(dashboard):
    status, reason, body, _ = _run(dashboard, members=",".join(ACCOUNTS))
    assert status == "SUCCESS", reason
    _assert_well_formed(body)
    rendered = json.dumps(body)
    for account in ACCOUNTS:
        assert account in rendered, f"{account} missing from explicit-mode dashboard"


@pytest.mark.parametrize("dashboard", DASHBOARDS)
def test_all_accounts_mode_is_well_formed_and_lists_no_accounts(dashboard):
    status, reason, body, _ = _run(dashboard, members="")
    assert status == "SUCCESS", reason
    _assert_well_formed(body)
    entries = list(_metric_entries(body))
    assert any(str(e.get("expression", "")).startswith("SELECT ") for e in entries), (
        "all-accounts mode should use Metrics Insights queries"
    )
    assert not any("accountId" in e for e in entries), (
        "all-accounts mode must not enumerate accounts in metric entries"
    )


@pytest.mark.parametrize("dashboard", sorted(HAS_LOG_ACCOUNTS))
def test_log_panels_follow_log_account_list(dashboard):
    _, _, without, _ = _run(dashboard, members="")
    status, reason, with_logs, _ = _run(dashboard, members="", log_accounts=",".join(LOG_ACCOUNTS))
    assert status == "SUCCESS", reason
    _assert_well_formed(with_logs)
    rendered_without = json.dumps(without)
    rendered_with = json.dumps(with_logs)
    for account in LOG_ACCOUNTS:
        assert account not in rendered_without
        assert account in rendered_with
    assert len(with_logs["widgets"]) > len(without["widgets"])


@pytest.mark.parametrize("dashboard", sorted(HAS_LOG_ACCOUNTS))
def test_log_panels_fall_back_to_member_accounts(dashboard):
    status, reason, body, _ = _run(dashboard, members=",".join(ACCOUNTS))
    assert status == "SUCCESS", reason
    log_widgets = [w for w in body["widgets"] if w.get("type") == "log"]
    assert {w["properties"].get("accountId") for w in log_widgets} >= set(ACCOUNTS)


# ---------------------------------------------------------------------
# Input validation and lifecycle
# ---------------------------------------------------------------------

@pytest.mark.parametrize("dashboard", DASHBOARDS)
@pytest.mark.parametrize("bad_id", ["12345", "abc", "1111111111111", "11111111111a"])
def test_bad_member_account_id_fails_without_writing_a_dashboard(dashboard, bad_id):
    status, reason, body, _ = _run(dashboard, members=f"{ACCOUNTS[0]},{bad_id}")
    assert status == "FAILED"
    assert body is None
    assert reason


@pytest.mark.parametrize("dashboard", sorted(HAS_LOG_ACCOUNTS))
def test_bad_log_account_id_fails_without_writing_a_dashboard(dashboard):
    status, _, body, _ = _run(dashboard, members="", log_accounts="12345")
    assert status == "FAILED"
    assert body is None


@pytest.mark.parametrize(
    "dashboard,prop",
    [(d, p) for d in DASHBOARDS for p in NAMESPACE_PROPS[d]],
)
@pytest.mark.parametrize("bad_namespace", ['x"y', "a b", "ns');DROP", ""])
def test_bad_namespace_fails_without_writing_a_dashboard(dashboard, prop, bad_namespace):
    status, _, body, _ = _run(dashboard, members="", **{prop: bad_namespace})
    assert status == "FAILED"
    assert body is None


@pytest.mark.parametrize("dashboard", DASHBOARDS)
def test_delete_removes_the_dashboard(dashboard):
    status, _, body, deleted = _run(dashboard, request_type="Delete")
    assert status == "SUCCESS"
    assert body is None
    assert deleted == [{"DashboardNames": ["test-dashboard"]}]
