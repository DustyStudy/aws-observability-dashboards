# fedramp-20x-audit-dashboard (Terraform)

Terraform module version of the FedRAMP 20x continuous-audit-evidence
dashboard. Functionally identical to the CloudFormation templates in
`cloudformation/fedramp-20x-audit-dashboard` — **see that folder's
[README.md](../../cloudformation/fedramp-20x-audit-dashboard/README.md) for
the full KSI-to-widget mapping and known limitations**; this file only
covers the Terraform-specific deploy steps.

## Prerequisites

Deploy these three modules in the same account(s) first, or the widgets that
read their namespaces will show no data:

- [`nhi-governance-dashboard`](../nhi-governance-dashboard)
- [`network-exposure-dashboard`](../network-exposure-dashboard)
- [`security-posture-dashboard`](../security-posture-dashboard)

## Deploy — single account

```hcl
module "fedramp_20x_audit_dashboard" {
  source = "./terraform/fedramp-20x-audit-dashboard"

  name_prefix                      = "fedramp-20x-audit"
  nhi_governance_namespace         = "NHIGovernance"
  network_exposure_namespace       = "NetworkExposure"
  security_observability_namespace = "SecurityObservability"
}
```

The three namespace variables must match whatever `metric_namespace` you
used for the other three modules — the defaults line up if you didn't
override theirs either.

## Deploy — org-wide

1. Deploy the `collector` submodule (via your own StackSets-equivalent
   multi-account deployment approach — Terraform has no native StackSets
   primitive) to every member account, alongside the collectors for the
   three prerequisite modules:

```hcl
module "fedramp_20x_audit_collector" {
  source = "./terraform/fedramp-20x-audit-dashboard/collector"

  name_prefix = "fedramp-20x-audit"
}
```

2. Deploy the `org-dashboard` submodule once, in your central monitoring
   account:

```hcl
module "fedramp_20x_audit_org_dashboard" {
  source = "./terraform/fedramp-20x-audit-dashboard/org-dashboard"

  # Leave member_account_ids out (or []) to show every linked account; list
  # account IDs to restrict the dashboard to them. See the two modes below.
  member_account_ids                = ["111111111111", "222222222222"]
  metric_namespace                  = "FedRAMP20xAudit"
  nhi_governance_namespace          = "NHIGovernance"
  network_exposure_namespace        = "NetworkExposure"
  security_observability_namespace  = "SecurityObservability"
}
```

See [`../../org-observability/README.md`](../../org-observability/README.md)
for the OAM Sink/Link setup this depends on.

`org-dashboard/` has two modes, chosen by `member_account_ids`:

- **All accounts (default, `member_account_ids = []`)**: each widget is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account, for example
  `SELECT SUM(ConfigRulesNonCompliant) FROM SCHEMA("FedRAMP20xAudit")`.
  The network-exposure metrics are Region-dimensioned, so they use
  `SCHEMA("NetworkExposure", Region)` (summed across regions), and the Open
  Security Group Rules panel adds `GROUP BY AWS.AccountId, Region`. The
  Security Hub standards score is a percentage, so it uses
  `AVG(SecurityHubStandardsScorePercent)` across accounts instead of `SUM`.
  There is no account list to maintain and no per-widget account ceiling.
- **Explicit list (`member_account_ids = ["111111111111", ...]`)**: one
  metric per account per series, limited to roughly 500/(series+1) accounts
  per widget. This is the behavior the dashboard had before all-accounts
  mode existed.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query; totals are
  unaffected, but the per-account Open Security Group Rules breakdown is
  truncated beyond that.
- Each total is a `SUM` over the period (86400 s). This dashboard's
  collector publishes each metric once per schedule (`rate(1 day)` by
  default; the multi-region collector publishes a single account-wide value
  per metric with the Region merged), so this is correct as long as the
  schedule is not shorter than one day; a shorter schedule would count an
  account more than once per period. The same applies to the
  nhi-governance, network-exposure and security-posture collectors whose
  metrics this dashboard also reads. The security-posture finding counts are
  event counts, so their `SUM` over the period is exact.
- The queries also include any metrics the monitoring account itself
  publishes in these namespaces.
- Use the explicit list to restrict the dashboard to specific accounts.

## Variables

| Variable | Default | Description |
|---|---|---|
| `name_prefix` | `fedramp-20x-audit` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `FedRAMP20xAudit` | Namespace this module's own collector publishes into |
| `audit_scan_schedule` | `rate(1 day)` | How often the scan runs |
| `nhi_governance_namespace` | `NHIGovernance` | Must match nhi-governance-dashboard's `metric_namespace` |
| `network_exposure_namespace` | `NetworkExposure` | Must match network-exposure-dashboard's `metric_namespace` |
| `security_observability_namespace` | `SecurityObservability` | Must match security-posture-dashboard's `metric_namespace` |

## Outputs

- `dashboard_name` / `dashboard_url`
- `audit_collector_function_name` / `audit_collector_log_group_name` — the
  collector's own logs, where flagged resource IDs (non-compliant rule
  names, failed backup job ARNs, Access Analyzer finding resources) are
  printed, since metrics only carry numbers

## Encryption & observability

Same as the CloudFormation version: a dedicated customer-managed KMS key
(rotation enabled) covers the collector's log group, environment variables,
and DLQ, and the collector Lambda has active AWS X-Ray tracing enabled.
