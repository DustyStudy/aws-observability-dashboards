# nhi-governance-dashboard (CloudFormation)

Dashboard for the non-human identity (NHI) risks security teams are being
asked about right now: stale/unrotated IAM access keys, console users
without MFA, IAM users nobody's used in 90+ days, IAM roles nobody's
assumed in 90+ days, roles that trust an external AWS account or a wildcard
principal, the account's workload identity federation footprint (OIDC/SAML
providers — GitHub Actions OIDC, EKS IRSA, and similar), and Secrets Manager
secrets that don't have rotation enabled.

A daily Lambda pulls the **IAM credential report** (the AWS-native mechanism
for auditing credential age/usage across every IAM user in one call) plus IAM
role metadata and identity provider lists, checks Secrets Manager rotation
status per region, and publishes counts as CloudWatch custom metrics.

IAM and STS are global services, so most of these metrics are account-wide
(not per-region). Secrets Manager is regional and gets its own per-region
breakdown.

## Prerequisites

- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- The Lambda's role needs IAM credential-report and read permissions
  (`iam:GenerateCredentialReport`, `iam:GetCredentialReport`,
  `iam:ListRoles`, `iam:ListOpenIDConnectProviders`,
  `iam:ListSAMLProviders`) — all read-only, none of them modify or delete
  anything

No QuickSight license required.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name nhi-governance-dashboard \
  --parameter-overrides \
      NamePrefix=nhi-governance \
      LogRetentionInDays=365 \
      StaleThresholdDays=90 \
  --capabilities CAPABILITY_NAMED_IAM
```

`CAPABILITY_NAMED_IAM` is required because this stack creates a named IAM role
for the NHI-collector Lambda.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `nhi-governance` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `NHIGovernance` | Namespace the collector publishes into |
| `StaleThresholdDays` | `90` | Age threshold for flagging access keys, IAM roles, and IAM users as stale/inactive |
| `GovernanceScanSchedule` | `rate(1 day)` | How often the scan runs |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `NhiCollectorFunctionName` — for checking Lambda logs/invocations directly
- `NhiCollectorLogGroupName` — **this is where the actual flagged identities
  live.** The dashboard shows *counts*; the collector's own CloudWatch Logs
  show the specific usernames, role names, and secret names behind those
  counts, since metrics can only carry numbers, not names.

## What each metric actually measures

- **Stale Access Keys** — active access keys not rotated in `StaleThresholdDays`
  (via `access_key_N_last_rotated` in the credential report)
- **Users Without MFA** — IAM users with a console password enabled but no
  MFA device active. Pure service accounts (access keys only, no console
  password) are intentionally excluded — MFA doesn't apply to them
- **Inactive IAM Users** — users older than the threshold whose password and
  all active access keys have gone unused for that long (or never been used)
- **Stale IAM Roles** — roles (excluding AWS service-linked roles) with no
  `RoleLastUsed` activity in the threshold window, or never assumed at all
- **External-Trust Roles** — roles whose trust policy allows a different AWS
  account or a wildcard (`"AWS": "*"`) principal to assume them. This
  doesn't flag `Service` or `Federated` principals (Lambda execution roles,
  OIDC-federated roles) as "external" — those are normal and tracked
  separately via the identity-provider metrics
- **OIDC / SAML Providers** — count of workload identity federation
  providers configured in the account

## Known limitations

- **Single-account scan.** For an AWS Organization, deploy via StackSets to
  every member account, or extend the Lambda with cross-account
  `sts:AssumeRole`.
- **The credential report only covers IAM users**, not IAM roles' own
  temporary credentials or federated/SSO identities — this dashboard's
  "non-human identity" coverage is IAM users, IAM roles, and workload
  federation, not a full inventory of every credential type in the account
  (no coverage of Cognito identity pools or third-party IdP-issued tokens,
  for example).
- **This is a triage/awareness tool**, not a policy engine — it doesn't
  auto-remediate anything (no key rotation, no role deletion). Pair it with
  the security-posture-dashboard in this repo, or with dedicated tools like
  IAM Access Analyzer, for enforcement.
- Report generation via `GenerateCredentialReport`/`GetCredentialReport` is
  asynchronous; the Lambda polls for completion with a short retry loop,
  which is normally fast but can occasionally add a few seconds to cold runs.

## Encryption

The NHI-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Observability

The NHI-collector Lambda has active AWS X-Ray tracing enabled, so a slow or
failing run (e.g. credential report generation taking longer than usual)
shows up as a trace in the X-Ray console, not just a CloudWatch Logs line.

## Extending

To track additional non-human identity surfaces, the same pattern applies:
Cognito identity pool role mappings, EKS IRSA role bindings (via the OIDC
provider already surfaced here), or GitHub Actions OIDC trust relationships
specifically (a subset of the external-trust-roles check, if you want it
broken out on its own).
