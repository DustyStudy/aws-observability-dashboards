terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}

# -----------------------------------------------------------------------
# General recipe used throughout this file: for any un-dimensioned metric
# a collector publishes locally in every account, build one hidden
# per-account metric entry (each carrying its own "accountId") plus one
# visible SUM() expression that adds them all up. This is the same
# approach the CloudFormation version implements with a Lambda-backed
# custom resource — Terraform can do it natively with `for` because HCL
# has real loops and jsonencode(), unlike CloudFormation's DashboardBody
# string. Apply this same `metric_groups` pattern to org-ify any of the
# other six dashboards in this repo.
# -----------------------------------------------------------------------
locals {
  metric_specs = {
    stale_keys     = { metric_name = "StaleAccessKeys", stat = "Maximum", id_prefix = "sk", label = "Stale Access Keys (org-wide)" }
    no_mfa         = { metric_name = "UsersWithoutMfa", stat = "Maximum", id_prefix = "mfa", label = "Users Without MFA (org-wide)" }
    inactive_users = { metric_name = "InactiveIamUsers", stat = "Maximum", id_prefix = "iu", label = "Inactive IAM Users (org-wide)" }
    stale_roles    = { metric_name = "StaleIamRoles", stat = "Maximum", id_prefix = "sr", label = "Stale IAM Roles (org-wide)" }
    external_trust = { metric_name = "ExternalTrustRoles", stat = "Maximum", id_prefix = "et", label = "External-Trust Roles (org-wide)" }
    total_keys     = { metric_name = "TotalActiveAccessKeys", stat = "Maximum", id_prefix = "tk", label = "Total Active Keys" }
    total_roles    = { metric_name = "TotalIamRoles", stat = "Maximum", id_prefix = "tr", label = "Total Roles" }
    oidc           = { metric_name = "OidcProviders", stat = "Maximum", id_prefix = "oi", label = "OIDC" }
    saml           = { metric_name = "SamlProviders", stat = "Maximum", id_prefix = "sa", label = "SAML" }
  }

  # Every value here is a ready-to-use `metrics` array: N hidden
  # per-account entries + 1 visible SUM() expression summing all of them.
  # Split into two flat maps (accounts, totals) rather than one deeply
  # nested concat/for expression — simpler to read and to keep formatted.
  metric_group_accounts = {
    for key, spec in local.metric_specs : key => [
      for i, acct in var.member_account_ids : [
        var.metric_namespace, spec.metric_name,
        { stat = spec.stat, period = 86400, accountId = acct, id = "${spec.id_prefix}${i}", visible = false }
      ]
    ]
  }

  metric_group_totals = {
    for key, spec in local.metric_specs : key => [[{
      expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
      label      = spec.label
      id         = "total_${spec.id_prefix}"
    }]]
  }

  metric_groups = {
    for key, spec in local.metric_specs : key => concat(local.metric_group_accounts[key], local.metric_group_totals[key])
  }

  # The "Workload Identity Providers" single-value widget shows one number
  # (OIDC + SAML combined): both per-metric totals are computed hidden,
  # then summed again into a final visible expression.
  identity_provider_hidden_oidc = [
    for i, acct in var.member_account_ids : [
      var.metric_namespace, "OidcProviders",
      { stat = "Maximum", period = 86400, accountId = acct, id = "pio${i}", visible = false }
    ]
  ]
  identity_provider_hidden_saml = [
    for i, acct in var.member_account_ids : [
      var.metric_namespace, "SamlProviders",
      { stat = "Maximum", period = 86400, accountId = acct, id = "pis${i}", visible = false }
    ]
  ]
  identity_provider_single_value_metrics = concat(
    local.identity_provider_hidden_oidc,
    [[{ expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "pio${i}"])}])", id = "pio_total", visible = false }]],
    local.identity_provider_hidden_saml,
    [[{ expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "pis${i}"])}])", id = "pis_total", visible = false }]],
    [[{ expression = "pio_total+pis_total", label = "Identity Providers (org-wide)", id = "provider_total" }]]
  )

  # Secrets Manager is genuinely multi-dimensional per account (it breaks
  # out by Region within each account), so this one stays as one SEARCH
  # expression per account rather than collapsing to a single sum.
  secrets_by_account_region_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = "SEARCH('{${var.metric_namespace},Region} MetricName=\"SecretsWithoutRotation\"', 'Maximum', 86400)"
      id         = "sec${i}"
      accountId  = acct
      label      = "${acct} - $${PROP('Dim.Region')}"
    }]
  ]
}

resource "aws_cloudwatch_dashboard" "nhi_governance_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.stale_keys.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.stale_keys
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.no_mfa.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.no_mfa
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.inactive_users.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.inactive_users
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.stale_roles.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.stale_roles
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.external_trust.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.external_trust
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Workload Identity Providers (OIDC+SAML, org-wide)"
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.identity_provider_single_value_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title   = "Access Keys: Total vs Stale (org-wide trend)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.total_keys, local.metric_groups.stale_keys)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title   = "IAM Roles: Total vs Stale (org-wide trend)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.total_roles, local.metric_groups.stale_roles)
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 6
        properties = {
          title   = "Secrets Manager – Secrets Without Rotation by Account/Region"
          view    = "bar"
          region  = data.aws_region.current.name
          metrics = local.secrets_by_account_region_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 6
        properties = {
          title   = "Workload Identity Providers – OIDC vs SAML (org-wide)"
          view    = "bar"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.oidc, local.metric_groups.saml)
        }
      },
    ]
  })
}
