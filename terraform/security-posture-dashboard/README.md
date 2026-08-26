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
  log_retention_in_days = 90
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
| `log_retention_in_days` | `90` | Retention for the two Logs groups |
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
