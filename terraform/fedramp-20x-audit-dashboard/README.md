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

1. Deploy this module's collector (via your own StackSets-equivalent
   multi-account deployment approach — Terraform has no native StackSets
   primitive) to every member account, alongside the collectors for the
   three prerequisite modules.
2. Deploy the `org-dashboard` submodule once, in your central monitoring
   account:

```hcl
module "fedramp_20x_audit_org_dashboard" {
  source = "./terraform/fedramp-20x-audit-dashboard/org-dashboard"

  member_account_ids                = ["111111111111", "222222222222"]
  metric_namespace                  = "FedRAMP20xAudit"
  nhi_governance_namespace          = "NHIGovernance"
  network_exposure_namespace        = "NetworkExposure"
  security_observability_namespace  = "SecurityObservability"
}
```

See [`../../org-observability/README.md`](../../org-observability/README.md)
for the OAM Sink/Link setup this depends on.

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
