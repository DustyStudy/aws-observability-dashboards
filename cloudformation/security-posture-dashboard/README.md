# security-posture-dashboard (CloudFormation)

CloudWatch dashboard covering Security Hub findings and GuardDuty findings:
severity breakdown, top failing controls, findings by type, and an hourly trend.

## Prerequisites

- Security Hub enabled in this account/region (for the Security Hub widgets)
- GuardDuty enabled in this account/region (for the GuardDuty widgets)
- Permissions to create: KMS key + alias, CloudWatch Logs groups + resource
  policies, EventBridge rules, CloudWatch Logs metric filters, CloudWatch
  dashboards

No QuickSight license required — everything renders in the native CloudWatch
Dashboards console.

## Encryption

Both log groups are encrypted at rest with a dedicated customer-managed KMS
key (key rotation enabled). The key policy grants the account root full
administration and scopes the CloudWatch Logs service principal's
encrypt/decrypt permissions to this account's log groups via an
`aws:logs:arn` condition.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name security-posture-dashboard \
  --parameter-overrides NamePrefix=security-posture LogRetentionInDays=365
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `security-posture` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the two Logs groups (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `SecurityObservability` | Namespace for the custom metrics this stack creates |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `SecurityHubLogGroupName` / `GuardDutyLogGroupName` — for building your own
  additional Logs Insights queries on top of the same data

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

This stack is really three reusable primitives:
EventBridge rule → CloudWatch Logs group → Logs Insights-powered dashboard
widgets. To add a new source (Config, Access Analyzer, Inspector, etc.), copy
the log group + EventBridge rule pair, point a new EventBridge rule at that
service's event pattern, and add widgets querying the new log group.
