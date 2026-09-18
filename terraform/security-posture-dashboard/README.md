# security-posture-dashboard (Terraform)

Terraform module version of the CloudWatch dashboard covering Security Hub
findings and GuardDuty findings — severity breakdown, top failing controls,
findings by type, and an hourly trend. Functionally identical to the
CloudFormation template in `cloudformation/security-posture-dashboard`.

## Prerequisites

- Security Hub enabled in this account/region (for the Security Hub widgets)
- GuardDuty enabled in this account/region (for the GuardDuty widgets)
- Terraform >= 1.5.0, AWS provider >= 5.0
- Permissions to create: KMS key + alias, CloudWatch Logs groups + resource
  policies, EventBridge rules, CloudWatch Logs metric filters, CloudWatch
  dashboards

No QuickSight license required.

## Usage

```hcl
module "security_posture_dashboard" {
  source = "./terraform/security-posture-dashboard"

  name_prefix           = "security-posture"
  log_retention_in_days = 365
}
```

```bash
terraform init
terraform plan
terraform apply
```

## Inputs

| Name | Default | Description |
|---|---|---|
| `name_prefix` | `security-posture` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the two Logs groups (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `SecurityObservability` | Namespace for the custom metrics this module creates |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `security_hub_log_group_name` / `guardduty_log_group_name` — for building
  your own additional Logs Insights queries on top of the same data

## Encryption

Both log groups are encrypted at rest with a dedicated customer-managed KMS
key (key rotation enabled). The key policy grants the account root full
administration and scopes the CloudWatch Logs service principal's
encrypt/decrypt permissions to this account's log groups via an
`aws:logs:arn` condition.

## Known limitation

The metric filters and the "by severity" / "by control" queries assume one
finding per event (`detail.findings[0]`). Security Hub can deliver multiple
findings in a single `Findings - Imported` event; when that happens the
single-value metric counts will undercount relative to total log volume. If
that gap matters for your use case, add a Lambda between EventBridge and the
log group to fan out multi-finding events into one log entry per finding —
everything downstream (metric filters, queries, dashboard) keeps working
unchanged, since it's a JSON-log-fed pattern.

## Extending

This module is really three reusable primitives:
EventBridge rule → CloudWatch Logs group → Logs Insights-powered dashboard
widgets. To add a new source (Config, Access Analyzer, Inspector, etc.), copy
the log group + event rule/target pair, point a new `aws_cloudwatch_event_rule`
at that service's event pattern, and add widgets querying the new log group.

## Org-wide deployment

To see Security Hub and GuardDuty findings for every account in an AWS
Organization on one dashboard, use the per-account collector plus a single
central dashboard. This builds on CloudWatch cross-account observability
(Observability Access Manager, OAM); see
[`org-observability/README.md`](../../org-observability/README.md) for the
one-time sink setup.

1. **Deploy the collector to every member account.** `collector/` is this
   module minus the dashboard: the KMS key, the two log groups, the EventBridge
   rules, and the metric filters. Roll it out to member accounts with
   CloudFormation StackSets using `cloudformation/security-posture-dashboard/collector.yaml`
   (see the StackSets steps in `org-observability/README.md`), or apply
   `collector/` in each account with your own Terraform pipeline. Security Hub
   and/or GuardDuty must be enabled in each account/region.
2. **Create the OAM link in every member account** (StackSet from
   `org-observability/oam-link/`), sharing Metrics and Logs with the
   monitoring account's OAM sink. Without the link, the central dashboard
   cannot read the members' metrics or log groups.
3. **Apply `org-dashboard/` once, in the monitoring account:**
   ```hcl
   module "security_posture_org_dashboard" {
     source = "./terraform/security-posture-dashboard/org-dashboard"

     member_account_ids = ["111111111111", "222222222222", "333333333333"]
   }
   ```

| Variable | Default | Description |
|---|---|---|
| `dashboard_name` | `security-posture-org-dashboard` | Name of the central dashboard |
| `member_account_ids` | (required) | Member account IDs to include (1 to 99 accounts) |
| `metric_namespace` | `SecurityObservability` | Must match the collector's `metric_namespace` |
| `name_prefix` | `security-posture` | Must match the collector's `name_prefix`; forms the log group names `/observability/<name_prefix>/security-hub-findings` and `/observability/<name_prefix>/guardduty-findings` |

The module has one output, `dashboard_url`.

How the widgets are converted:

- The three single-value metrics (Security Hub Critical, Security Hub High,
  GuardDuty High Severity, 24h) become one hidden per-account metric entry each
  plus one visible `SUM()` across accounts.
- Logs Insights widgets cannot be collapsed across accounts: a CloudWatch log
  widget takes a single `accountId`. Each of the five log panels (Security Hub
  volume, by severity, top failing controls; GuardDuty by type, hourly trend)
  is therefore rendered once per member account, with the account ID in the
  widget title, in a non-overlapping grid.

### Limitations

- CloudWatch allows at most 500 metrics per widget. This pattern uses one
  metric per account per series, plus one expression, so a widget with S
  series supports roughly 500/(S+1) accounts. The metric tiles here have one
  series each, which is about 250 accounts.
- Log panels add one widget per account per panel (5 per account, plus 3
  metric widgets), and a dashboard is capped at 500 widgets. The module
  therefore accepts at most 99 accounts (enforced by a variable validation).
  Very large organizations should split accounts across several
  org-dashboards: apply the module multiple times with a different
  `dashboard_name` and a different subset of `member_account_ids` each time.
- As with the single-account dashboard, the metrics and the severity/control
  panels assume one finding per event (`detail.findings[0]`).
