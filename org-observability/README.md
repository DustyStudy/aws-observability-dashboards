# Org-wide, multi-account deployment

Every dashboard in this repo was originally a single-account deployment.
This directory adds the pieces needed to run them across an entire AWS
Organization instead: one central **monitoring account** with a dashboard
that shows every other account's data, built on CloudWatch's native
**Observability Access Manager (OAM)**.

## How it fits together

- **A dedicated monitoring account** (recommended over reusing your
  Organizations management account) holds:
  - An **OAM Sink** (`oam-sink/`) — the attachment point other accounts
    link to.
  - The **org-dashboard** stack for each dashboard you want centralized
    (e.g. `cloudformation/nhi-governance-dashboard/org-dashboard.yaml`).
- **Every other account in the org** gets, via CloudFormation StackSets:
  - An **OAM Link** (`oam-link/`) — opens the sharing relationship with the
    sink above (Metrics + Logs + Traces).
  - The dashboard's **collector stack** (e.g.
    `cloudformation/nhi-governance-dashboard/collector.yaml`) — the actual
    Lambda/EventBridge/KMS infrastructure that scans that account and
    publishes metrics locally. This is *unchanged* from the single-account
    version, just deployed everywhere instead of once.

Nothing about the collectors themselves changes for org-wide use — each one
still only ever sees its own account. OAM is what lets the monitoring
account's dashboards read those local metrics without you building any
data pipeline between accounts.

## Why StackSets, not a central scanning Lambda

An earlier option considered was a single Lambda in the monitoring account
that assumes a role into every member account and scans them centrally.
That was rejected: one Lambda execution role with `sts:AssumeRole` rights
into every account in your org is a much bigger blast radius than each
account quietly running its own narrowly-scoped local collector — a bad
trade for a security-tooling repo. StackSets deploying the same
already-least-privilege collector stack everywhere keeps that property
intact at any scale.

## One-time setup (do this once, ever)

1. **Enable trusted access for StackSets with Organizations**, from your
   Organizations management account. This lets you target OUs with
   `SERVICE_MANAGED` StackSets without hand-creating IAM roles in every
   member account:
   ```bash
   aws organizations enable-aws-service-access \
     --service-principal member.org.stacksets.cloudformation.amazonaws.com
   ```

2. **Deploy the OAM Sink once**, by hand, in your chosen monitoring
   account:
   ```bash
   aws cloudformation deploy \
     --template-file oam-sink/template.yaml \
     --stack-name org-observability-sink \
     --parameter-overrides OrganizationId=o-xxxxxxxxxx \
     --region us-east-1
   ```
   Note the `SinkArn` output — every account's Link needs it.

## Roll out to every account (repeat whenever you add a dashboard)

3. **Create a StackSet for the OAM Link**, targeting your whole
   organization (or specific OUs):
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name org-observability-link \
     --template-body file://oam-link/template.yaml \
     --permission-model SERVICE_MANAGED \
     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
     --parameters ParameterKey=MonitoringSinkArn,ParameterValue=<SinkArn-from-step-2> \
     --region us-east-1

   aws cloudformation create-stack-instances \
     --stack-set-name org-observability-link \
     --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id> \
     --regions us-east-1 \
     --region us-east-1
   ```

4. **Create a StackSet for each dashboard's collector**, the same way —
   for example, NHI governance:
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name nhi-governance-collector \
     --template-body file://../cloudformation/nhi-governance-dashboard/collector.yaml \
     --permission-model SERVICE_MANAGED \
     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1

   aws cloudformation create-stack-instances \
     --stack-set-name nhi-governance-collector \
     --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id> \
     --regions us-east-1 \
     --region us-east-1
   ```
   Repeat for `bedrock-usage-cost-dashboard`, `ai-service-inventory-dashboard`,
   `network-exposure-dashboard`, `eks-security-dashboard`, and
   `agentic-ai-guardrails-dashboard` / `security-posture-dashboard` once
   they're split into collector/org-dashboard pairs (see below).

5. **Deploy the org-dashboard once**, in the monitoring account, after the
   collectors have run at least once (give it a day, since most collectors
   are scheduled `rate(1 day)`):
   ```bash
   aws cloudformation deploy \
     --template-file ../cloudformation/nhi-governance-dashboard/org-dashboard.yaml \
     --stack-name nhi-governance-org-dashboard \
     --parameter-overrides MemberAccountIds=111111111111,222222222222,333333333333 \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1
   ```
   Terraform users: apply `terraform/nhi-governance-dashboard/org-dashboard/`
   directly (`member_account_ids` variable), no StackSets needed for this
   one piece since it only deploys once.

## Current status: two dashboards fully converted

**nhi-governance-dashboard** and **agentic-ai-guardrails-dashboard** are
complete reference implementations, covering the two distinct widget
patterns you'll need for the rest:

- **nhi-governance**: simple un-dimensioned metrics (`StaleAccessKeys`,
  `TotalIamRoles`, etc.) — the `metric_groups`/`_sum_across_accounts`
  pattern (N hidden per-account entries + one visible `SUM()`).
- **agentic-ai-guardrails**: `SEARCH()`-based metrics with no per-account
  collector at all (Bedrock publishes them natively) — the
  `search_groups`/`combine_search` pattern, plus the important refinement
  that **count-style metrics combine with `SUM()`, latency-style metrics
  combine with `AVG()`** (summing averages across accounts would be
  meaningless — this was a deliberate design decision, not an oversight).
  Its `GuardrailPolicyType`-dimensioned widget also demonstrates the
  "variable series per account, don't collapse to one number" case: one
  visible `SEARCH()` per account shown side by side.

Both were verified by extracting and actually *running* the widget-building
logic against fake multi-account data (not just checking that the code
compiles) — this caught a real bug during the nhi-governance build (metric
math ID collisions when a single widget combines two metric groups) that a
syntax check alone would have missed.

The other five dashboards
(`security-posture`, `bedrock-usage-cost`, `ai-service-inventory`,
`network-exposure`, `eks-security`) have their `collector.yaml`/`collector/`
already split out and ready for StackSets, but still need their
`org-dashboard` built. Three of them
(`security-posture`, `network-exposure`, `eks-security`) also include **log
widgets** (Logs Insights over Security Hub/GuardDuty/Inspector/VPC Flow Log
data), which need a third pattern not yet demonstrated here: CloudWatch's
cross-account log widgets take a single `accountId` per widget (confirmed
from AWS docs — not an array, and not a "search all accounts" mode), so the
correct approach is one widget per account per log panel, rather than
collapsing to a single number the way metrics can.

### The recipe to convert another dashboard

1. **Split the existing template**: copy `template.yaml`/`main.tf` to
   `collector.yaml`/`collector/`, delete the `AWS::CloudWatch::Dashboard` /
   `aws_cloudwatch_dashboard` resource and its outputs. That's the whole
   collector — nothing else changes. (Already done for all seven dashboards
   in this repo.)
2. **Build the org-dashboard**:
   - **Terraform**: natively, with `for` expressions — see either
     `terraform/nhi-governance-dashboard/org-dashboard/main.tf` (simple
     metrics) or
     `terraform/agentic-ai-guardrails-dashboard/org-dashboard/main.tf`
     (`SEARCH()`-based, with the SUM/AVG distinction).
   - **CloudFormation**: needs a Lambda-backed custom resource, since CFN
     can't loop-generate JSON inside a `DashboardBody` string — see the
     matching `.yaml` files for the Python equivalents of the two patterns
     above.
   - **Log widgets**: one widget per account, each with its own `accountId`
     and `region` in `properties` — not yet demonstrated in this repo, but
     the schema is confirmed (AWS docs: `CloudWatch-Dashboard-Body-Structure.html`).
3. **Watch for ID collisions**: every metric-math `id` must be unique
   *within a single widget's metrics array*. If a widget combines two
   metric/search groups (e.g., "Total vs Stale" trend lines, or "OIDC vs
   SAML"), give each group's per-account IDs a distinct prefix — this was
   an actual bug caught by testing, not a hypothetical one, and it recurred
   (in a different form) in the agentic-ai-guardrails conversion too, so
   treat it as the standing risk to check for on every new widget.
4. Add a `#checkov:skip=CKV_AWS_117` / `CKV_AWS_272` note (or rely on this
   repo's CI-level `skip_check`) on the org-dashboard's generator Lambda,
   same as every other collector Lambda in this repo.

## Cost and query-limit notes

- Cross-account metric retrieval has no additional CloudWatch charge
  beyond standard pricing, but counts toward the monitoring account's API
  call quotas — keep an eye on this with very large organizations.
- A single dashboard widget supports up to 500 metrics, and a dashboard up
  to 2,500 across all widgets. The `SUM()`-of-all-accounts pattern here
  uses one metric per account per group, so this becomes a real ceiling
  somewhere in the high hundreds of accounts — StackSets and OAM
  themselves scale to 100,000 source accounts per sink, but a single
  dashboard's widget math does not.
