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

## Org-wide deployment

To see Security Hub and GuardDuty findings for every account in an AWS
Organization on one dashboard, split this stack into a per-account collector
plus a single central dashboard. This builds on CloudWatch cross-account
observability (Observability Access Manager, OAM); see
[`org-observability/README.md`](../../org-observability/README.md) for the
one-time sink setup.

1. **Deploy the collector to every member account via StackSets.**
   `collector.yaml` is this template minus the dashboard: the KMS key, the two
   log groups, the EventBridge rules, and the metric filters. Deploy it as a
   `SERVICE_MANAGED` StackSet targeting your OUs (Security Hub and/or
   GuardDuty must be enabled in each account/region):
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name security-posture-collector \
     --template-body file://collector.yaml \
     --permission-model SERVICE_MANAGED \
     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1

   aws cloudformation create-stack-instances \
     --stack-set-name security-posture-collector \
     --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id> \
     --regions us-east-1 \
     --region us-east-1
   ```
2. **Create the OAM link in every member account** (StackSet from
   `org-observability/oam-link/`), sharing Metrics and Logs with the
   monitoring account's OAM sink. Without the link, the central dashboard
   cannot read the members' metrics or log groups.
3. **Deploy `org-dashboard.yaml` once, in the monitoring account**, after the
   collectors have received some findings. To cover every linked account and
   add per-account log panels for two of them:
   ```bash
   aws cloudformation deploy \
     --template-file org-dashboard.yaml \
     --stack-name security-posture-org-dashboard \
     --parameter-overrides LogAccountIds=111111111111,222222222222 \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1
   ```

`org-dashboard.yaml` uses a small Lambda-backed custom resource to generate the
`DashboardBody`, because CloudFormation cannot loop over account IDs inside a
JSON string. The Lambda has permissions only for this one dashboard.

The metric tiles have two modes, chosen by the `MemberAccountIds` parameter:

- **All accounts (default, `MemberAccountIds` left empty)**: each tile is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account, for example
  `SELECT SUM(SecurityHubCriticalFindings) FROM SCHEMA("SecurityObservability")`.
  There is no account list to maintain and no per-widget account ceiling.
- **Explicit list (`MemberAccountIds=111111111111,222222222222`)**: one metric
  per account per series, limited to roughly 500/(series+1) accounts per
  widget. This is the original behavior and is unchanged.

Log panels are always per-account, because a CloudWatch log widget takes a
single `accountId` and Metrics Insights does not apply to logs. They are
emitted for `LogAccountIds` if set, otherwise for `MemberAccountIds` (so
explicit mode behaves as before). In all-accounts mode with no
`LogAccountIds`, the dashboard has no log panels and shows a text widget
saying so.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query. Each tile
  query returns a single summed series, so the totals are not affected.
- Each tile is a `SUM` over the period (86400 s), so it is only correct if
  the metric is published at most once per period per account. That holds
  here: the collector's metric filters (`MetricValue: "1"`, `DefaultValue: 0`)
  emit a per-event count for each period rather than a repeated snapshot, so
  summing them over a day gives the number of matching findings in that day.
- The queries also include any metrics the monitoring account itself
  publishes in this namespace.
- Use the explicit list (`MemberAccountIds`) to restrict the tiles to specific
  accounts.

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `security-posture-org-dashboard` | Name of the central dashboard |
| `MemberAccountIds` | (empty) | Comma-delimited 12-digit account IDs; empty = all linked accounts (Metrics Insights), otherwise one metric per listed account |
| `LogAccountIds` | (empty) | Comma-delimited 12-digit account IDs to get per-account log panels (at most 99); empty = use `MemberAccountIds`, and if that is also empty there are no log panels |
| `MetricNamespace` | `SecurityObservability` | Must match the collector's `MetricNamespace` |
| `NamePrefix` | `security-posture` | Must match the collector's `NamePrefix`; forms the log group names `/observability/<NamePrefix>/security-hub-findings` and `/observability/<NamePrefix>/guardduty-findings` |
| `LogRetentionDays` | `365` | Retention for the generator Lambda's own log group |

How the widgets are converted:

- The three single-value metrics (Security Hub Critical, Security Hub High,
  GuardDuty High Severity, 24h) become, in all-accounts mode, one
  `SELECT SUM(<metric>) FROM SCHEMA("<namespace>")` query each; in explicit
  mode, one hidden per-account metric entry each plus one visible `SUM()`
  across accounts.
- Logs Insights widgets cannot be collapsed across accounts: a CloudWatch log
  widget takes a single `accountId`. Each of the five log panels (Security Hub
  volume, by severity, top failing controls; GuardDuty by type, hourly trend)
  is therefore rendered once per log account (`LogAccountIds`, else
  `MemberAccountIds`), with the account ID in the widget title, in a
  non-overlapping grid.

### Limitations

- In explicit mode, CloudWatch allows at most 500 metrics per widget. This
  pattern uses one metric per account per series, plus one expression, so a
  widget with S series supports roughly 500/(S+1) accounts. The metric tiles
  here have one series each, which is about 250 accounts. All-accounts mode
  has no such account ceiling.
- Log panels add one widget per log account per panel (5 per account, plus 3
  metric widgets), and a dashboard is capped at 500 widgets. The list of log
  accounts (`LogAccountIds`, else `MemberAccountIds`) is therefore limited to
  99 accounts, and the deployment fails beyond that. To cover more accounts
  with log panels, deploy this stack multiple times with a different
  `DashboardName` and a different subset of `LogAccountIds` each time.
- As with the single-account dashboard, the metrics and the severity/control
  panels assume one finding per event (`detail.findings[0]`).
