# network-exposure-dashboard (Terraform)

Terraform module version of the network exposure dashboard. Functionally
identical to the CloudFormation template in
`cloudformation/network-exposure-dashboard`.

Covers internet-facing exposure across an account: security groups open to
the internet on sensitive ports, EC2 instances with public IPs, publicly
accessible RDS instances, internet-facing load balancers, publicly exposed S3
buckets — plus, if you already ship VPC Flow Logs to CloudWatch,
rejected-connection trends, top source IPs, and a simple port-scan detector.

A daily Lambda scans every enabled region for the compute/network resources
and publishes counts as CloudWatch custom metrics; the S3 check is
account-wide (S3 is a global service) and buckets are counted under their
home region. This module does not create or enable VPC Flow Logs itself —
that's a bigger decision (cost, per-ENI/VPC scope, retention) that belongs to
you, not a dashboard template.

## Prerequisites

- Terraform >= 1.5.0, AWS provider >= 5.0, `hashicorp/archive` provider >= 2.4
  (used to zip the exposure-collector Lambda source at plan/apply time)
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- **Optional:** an existing VPC Flow Logs delivery to a CloudWatch Logs group,
  using the **default log format** (the dashboard's Logs Insights queries
  rely on the auto-parsed `srcAddr`/`dstAddr`/`dstPort`/`action` field names
  CloudWatch recognizes for the default format — a custom flow log format
  will need the queries rewritten with an explicit `parse` statement)

No QuickSight license required.

## Usage

```hcl
module "network_exposure_dashboard" {
  source = "./terraform/network-exposure-dashboard"

  name_prefix               = "network-exposure"
  log_retention_in_days     = 365
  flow_logs_log_group_name  = "/vpc/flow-logs" # omit or leave "" if you have none
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
| `name_prefix` | `network-exposure` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `NetworkExposure` | Namespace the collector publishes into |
| `exposure_scan_schedule` | `rate(1 day)` | How often the scan runs |
| `flow_logs_log_group_name` | *(blank)* | Name of your **existing** VPC Flow Logs CloudWatch Logs group |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `exposure_collector_function_name` — for checking Lambda logs/invocations directly
- `exposure_collector_log_group_name` — **this is where the actual flagged
  resource identifiers live.** The dashboard shows *counts* by region;
  the collector's own CloudWatch Logs show the specific security group IDs,
  instance IDs, DB identifiers, load balancer names, and bucket names behind
  those counts, since metrics can only carry numbers, not names.

## What "sensitive ports" means here

The collector flags any security group rule open to `0.0.0.0/0` or `::/0`,
and separately calls out the subset on these ports: `22, 3389, 3306, 5432,
1433, 27017, 6379, 9200, 5900` (SSH, RDP, and common database/cache ports).
Edit the `SENSITIVE_PORTS` set in
`lambda/network_exposure_collector.py` and re-apply to match your own
environment's risk list.

## S3 public-access detection method

A bucket is flagged public if either:
- `GetBucketPolicyStatus` reports `IsPublic: true` (policy-based public access), or
- its ACL grants to the `AllUsers` group (legacy ACL-based public access)

This does **not** separately account for S3 Block Public Access settings —
a bucket can have a technically-public policy or ACL while Block Public
Access still prevents actual public reads. Treat a flag here as "worth a
second look," not a confirmed open bucket; verify in the console or via
`s3:GetBucketPolicyStatus` directly before acting.

## Known limitations

- **This module is a single-account dashboard and scan.** For an AWS
  Organization, use the org-wide option below (the `collector/` module in every
  member account plus one `org-dashboard/` in a central monitoring account)
  rather than adding cross-account `sts:AssumeRole` to the Lambda.
- **The Lambda's `SENSITIVE_PORTS` port list and public-detection logic are
  intentionally simple** — this is a triage/awareness tool, not a
  replacement for AWS Config rules, Security Hub, or IAM Access Analyzer for
  authoritative compliance findings. Pair it with the
  security-posture-dashboard in this repo for that.
- The 300-second Lambda timeout allows for scanning security groups,
  instances, RDS, and load balancers across every enabled region — if you
  have very large security group counts, watch the collector's own duration
  in its CloudWatch Logs.

## Encryption

The exposure-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Observability

The exposure-collector Lambda has active AWS X-Ray tracing enabled, so a
slow or failing multi-region scan shows up as a trace in the X-Ray console,
not just a CloudWatch Logs line.

## Extending

To flag additional resource types (CloudFront distributions, API Gateway
endpoints, EFS mount targets), add a check function to the Lambda following
the same pattern (describe the resource, test its public-facing condition,
append to `metric_data` and `findings`), and add a widget referencing the new
metric name.

## Org-wide deployment

This module scans and displays a single account. To cover an entire AWS
Organization, use the two halves this folder already splits out:

- `collector/` - the per-account scanner (same Lambda, metrics, and KMS/DLQ
  hardening as this module, minus the dashboard), applied in every member
  account.
- `org-dashboard/` - ONE dashboard in a central monitoring account that reads
  every member account's local metrics and logs through CloudWatch
  cross-account observability (OAM). It contains no scanning logic.

`org-dashboard/` has two modes, chosen by `member_account_ids`:

- **All accounts (default, `member_account_ids = []`)**: the tiles and bar
  charts are CloudWatch Metrics Insights queries over every account linked to
  the monitoring account, for example
  `SELECT SUM(PublicEc2Instances) FROM SCHEMA("NetworkExposure", Region)` for a
  tile and the same query with `GROUP BY Region` for a bar chart. There is no
  account list to maintain and no per-widget account ceiling.
- **Explicit list (`member_account_ids = ["111111111111", ...]`)**: one
  metric per account per series, limited to roughly 500/(series+1) accounts
  per widget. This is the original behavior and is unchanged.

The VPC Flow Log panels are the exception: a Logs Insights widget takes a
single account, so they are **always per-account** and all-accounts mode cannot
enumerate accounts for them. Use `log_account_ids` to name the accounts; if it
is empty the panels use `member_account_ids`, and in all-accounts mode with no
`log_account_ids` no log panels are shown (a short text widget says how to
enable them).

Steps (the one-time sink setup is described in
[`org-observability/README.md`](../../org-observability/README.md)):

1. **OAM Sink** in the monitoring account (`org-observability/oam-sink`), and an
   **OAM Link** to it from every member account (`org-observability/oam-link`,
   sharing Metrics and Logs). Those templates are CloudFormation, so roll them
   out with a StackSet as described in that README.
2. **Collector**: apply `collector/` in every member account. Terraform has no
   StackSet equivalent, so either run it per account (a provider alias or one
   pipeline per account) or deploy the CloudFormation `collector.yaml` through
   a StackSet - both publish the same metrics. Keep `metric_namespace`
   identical everywhere.
3. **Apply the org-dashboard once**, in the monitoring account, after the
   collectors have run at least once (the default schedule is `rate(1 day)`):

   ```hcl
   # All accounts linked to this monitoring account (no account list needed):
   module "network_exposure_org_dashboard" {
     source = "./terraform/network-exposure-dashboard/org-dashboard"

     # Flow-log panels are per-account; name the accounts you want them for.
     flow_logs_log_group_name = "/vpc/flow-logs" # leave "" to omit the flow-log panels
     log_account_ids          = ["111111111111", "222222222222"]
   }
   ```

   or restrict it to specific accounts (flow-log panels then default to the
   same accounts):

   ```hcl
   module "network_exposure_org_dashboard" {
     source = "./terraform/network-exposure-dashboard/org-dashboard"

     member_account_ids       = ["111111111111", "222222222222", "333333333333"]
     flow_logs_log_group_name = "/vpc/flow-logs" # leave "" to omit the flow-log panels
   }
   ```

   or run it directly from that directory:

   ```bash
   terraform init
   terraform apply                                                   # all accounts
   terraform apply -var 'member_account_ids=["111111111111","222222222222"]'
   ```

### Org-dashboard inputs

| Name | Default | Description |
|---|---|---|
| `dashboard_name` | `network-exposure-org-dashboard` | Name of the cross-account dashboard |
| `member_account_ids` | `[]` (all accounts) | 12-digit account IDs to show, one metric per account. Empty uses Metrics Insights over every linked account |
| `log_account_ids` | `[]` | 12-digit account IDs to show the flow-log panels for. Empty falls back to `member_account_ids`; in all-accounts mode that means no log panels |
| `metric_namespace` | `NetworkExposure` | Must match the collector's `metric_namespace` (letters, digits, `_ . / -`) |
| `flow_logs_log_group_name` | *(blank)* | **Existing** VPC Flow Logs log group, queried by the same name in every account the log panels cover. Blank omits the three flow-log panels |

Outputs: `dashboard_name`, `dashboard_url`.

### What the org dashboard shows

- **24h tiles** (sensitive-port SG rules, public EC2, public RDS, internet-facing
  load balancers): org-wide totals summed across all accounts and regions.
  In all-accounts mode each is `SELECT SUM(<metric>) FROM SCHEMA("<namespace>", Region)`.
- **By Region bar charts** (the four above plus public S3 buckets): in explicit
  mode, one series per account per region, so you can see which account and
  region an exposure sits in. In all-accounts mode, one bar per region summed
  across the organization (`... GROUP BY Region`); there is no per-account
  breakdown, because that would be cut off at 500 series per query. Use the
  explicit list if you need to see which account an exposure sits in.
- **VPC Flow Log panels** (rejected-connection trend, top rejected source IPs,
  possible port scans): Logs Insights widgets cannot combine accounts, because
  a log widget takes a single `accountId`. The dashboard therefore repeats each
  panel once per log account (`log_account_ids`, else `member_account_ids`),
  with the account ID in the title, laid out two per row. Each account must
  already deliver default-format flow logs to the named log group; an account
  without it shows an empty widget.

### All-accounts mode: caveats

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query. The tiles and
  the per-region bars are far below that (one series per region), but if the
  collectors ever publish more than 500 matching series the results are
  truncated.
- Each `SUM` is taken over the period (86400 s). The collector publishes once
  per schedule (`rate(1 day)` by default, `exposure_scan_schedule` in
  `collector/`), so this is correct as long as the schedule is not shorter
  than one day; a shorter schedule would count each account more than once per
  period.
- The queries also include any metrics the monitoring account itself publishes
  in this namespace.
- Use the explicit `member_account_ids` list to restrict the dashboard to
  specific accounts.
- Log panels are always per-account (see above).

### Limits

CloudWatch allows at most 500 metrics per widget and 500 widgets per
dashboard. In all-accounts mode each metric widget carries a single query, so
there is no account ceiling for the metric widgets. In explicit mode this
pattern uses one metric per account per series (plus one `SUM()` for the
tiles), so a widget with S series supports roughly 500/(S+1) accounts; every
metric widget on this dashboard has a single series, which puts the ceiling at
499 accounts. Log panels are the tighter constraint and are capped by the log
account list in every mode: each of the three flow-log panels adds one widget
per log account (9 metric widgets + 3 x N log widgets), so with flow logs
enabled the dashboard tops out at 163 log accounts. Very large organizations
should keep `log_account_ids` to the accounts that need flow-log panels, or
split across several org-dashboards: apply the module multiple times with
different `dashboard_name` and account subsets (and leave the flow-log group
blank on all but the deployments that need those panels). Preconditions on the
dashboard resource fail the plan with a clear message if a single deployment
would exceed either limit.
