# aws-observability-dashboards

[![CI](https://github.com/DustyStudy/aws-observability-dashboards/actions/workflows/ci.yml/badge.svg)](https://github.com/DustyStudy/aws-observability-dashboards/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

CloudFormation and Terraform templates for CloudWatch dashboards that give cloud
security engineers visibility into security posture, AI/ML usage, and agentic AI
activity across an AWS account or org. Companion repo to
[fedramp-cfn-library](https://github.com/DustyStudy/fedramp-cfn-library),
[fedramp-terraform-library](https://github.com/DustyStudy/fedramp-terraform-library),
and [aws-cloud-security-toolbox](https://github.com/DustyStudy/aws-cloud-security-toolbox).

Every dashboard here is built on native **CloudWatch Dashboards + Logs Insights**,
not QuickSight. That's a deliberate choice for a public template repo:

- No extra licensing/per-user cost — CloudWatch is available in every account
- Built to work in both AWS commercial and AWS GovCloud (partition-aware
  ARNs throughout). The org-dashboards' default all-accounts mode uses
  CloudWatch Metrics Insights, whose GovCloud availability has not been
  confirmed; if it isn't available in your partition, pass an explicit
  account list instead
- Deployable and lintable in CI the same way as the other repos (cfn-lint/Checkov,
  tflint/Checkov)
- QuickSight dashboards require a `Definition`/analysis payload that's hundreds of
  lines of sheet/visual JSON per dashboard and isn't practical to keep generic —
  if you want a QuickSight version later, use these as the data-source layer and
  build the visual layer on top in your own account

## Repo layout

```
cloudformation/<dashboard-name>/template.yaml
terraform/<dashboard-name>/*.tf
```

Each dashboard folder is self-contained and deployable on its own.

## Dashboards

| Dashboard | Status | Org-wide | Description |
|---|---|---|---|
| [security-posture-dashboard](cloudformation/security-posture-dashboard) | ✅ Built | ✅ Full | Security Hub findings + GuardDuty findings — severity breakdown, top failing controls, findings by type, trend over time |
| [bedrock-usage-cost-dashboard](cloudformation/bedrock-usage-cost-dashboard) | ✅ Built | ✅ Full | Bedrock invocations, tokens, latency, errors/throttles by model (native metrics), plus estimated daily cost by usage type via a scheduled Cost Explorer collector |
| [agentic-ai-guardrails-dashboard](cloudformation/agentic-ai-guardrails-dashboard) | ✅ Built | ✅ Full | Bedrock Agents activity (invocations, latency, token usage, model-call health) + Bedrock Guardrails behavior (intervention rate, interventions by policy category, latency/errors) |
| [ai-service-inventory-dashboard](cloudformation/ai-service-inventory-dashboard) | ✅ Built | ✅ Full | Which regions actually have Bedrock, Bedrock Agents, Bedrock Guardrails, Rekognition, Comprehend, or Textract in active use — shadow AI adoption tracking via a scheduled multi-region CloudWatch scan |
| [network-exposure-dashboard](cloudformation/network-exposure-dashboard) | ✅ Built | ✅ Full | Internet-open security groups, public EC2/RDS/load balancers, exposed S3 buckets by region, plus optional VPC Flow Log rejected-connection trends and port-scan detection |
| [nhi-governance-dashboard](cloudformation/nhi-governance-dashboard) | ✅ Built | ✅ Full | Non-human identity risk: stale/unrotated access keys, users without MFA, inactive IAM users, stale IAM roles, external-trust roles, workload identity federation footprint, Secrets Manager rotation status |
| [eks-security-dashboard](cloudformation/eks-security-dashboard) | ✅ Built | ✅ Full | EKS cluster/nodegroup Kubernetes version drift, stale node AMIs, nodegroup health issues, public-only API endpoints, GuardDuty EKS Protection findings, Inspector container image vulnerabilities |
| [fedramp-20x-audit-dashboard](cloudformation/fedramp-20x-audit-dashboard) | ✅ Built | ✅ Full | Continuous audit evidence for FedRAMP 20x Key Security Indicators (KSIs), scanned across every enabled region, not just one, across 16 AWS services: Config compliance/auto-remediation, CloudTrail health, Backup coverage/outcomes, Access Analyzer findings, RDS/ASG HA posture, VPC endpoint/NACL posture, ACM/S3 secure-transport checks, a Security Hub pass/fail score, account-wide Inspector findings, EC2 instance-profile coverage, Trusted Advisor, whether GuardDuty/Security Hub/Inspector are actually enabled, EBS/RDS/S3 encryption defaults, IAM password policy strength — plus widgets pulling in this repo's other dashboards — every widget titled with the specific KSI ID it evidences |

"Org-wide" refers to the multi-account setup described below: every
dashboard here has a per-account collector (where one is needed) plus a
central org-dashboard that shows all member accounts together, in both
CloudFormation and Terraform. See
[`org-observability/`](org-observability/README.md) for the rollout steps.

All five dashboards from the original roadmap are built, plus a sixth
(nhi-governance) for non-human identity, a seventh (eks-security) for
Kubernetes/container security, and an eighth (fedramp-20x-audit) mapping
directly to FedRAMP 20x Key Security Indicators — added because they're
where a lot of current enterprise cloud security attention is going. Ideas
for further dashboards: CloudFront/API Gateway exposure, EFS/FSx public
mounts, SageMaker endpoint cost and utilization, or cross-account rollups of
any dashboard here via StackSets — see each dashboard's own README for its
specific "Extending" notes.

## How each dashboard is wired

Two patterns are used across this repo, not one - see
[`docs/PROOF.md`](docs/PROOF.md) for how that was confirmed.

**Event-driven** (`security-posture-dashboard`, `eks-security-dashboard`):

1. **EventBridge rule(s)** capture relevant events (Security Hub findings, GuardDuty
   findings)
2. Events land in a dedicated **CloudWatch Logs group**
3. **Metric filters** promote key fields (severity, finding type) into CloudWatch
   metrics for number/graph widgets
4. A **CloudWatch Dashboard** combines Logs Insights query widgets and metric
   widgets into one view

**Scheduled collector** (`bedrock-usage-cost`, `ai-service-inventory`,
`network-exposure`, `nhi-governance`, `fedramp-20x-audit`): an EventBridge
scheduled rule invokes a Lambda collector on a timer, which calls AWS APIs
directly and publishes the results as CloudWatch metrics for the dashboard
to read - no EventBridge event routing or Logs group involved.

`agentic-ai-guardrails-dashboard` uses neither - it reads Bedrock's own
native CloudWatch metrics directly.

For the event-driven pattern, every dashboard using it is really three building blocks
(EventBridge → Logs → Dashboard) that you can extend or recombine for your own
custom dashboards.

## Org-wide, multi-account deployment

By default every dashboard here is a single-account deployment
(`template.yaml` / `main.tf`). For running across an entire AWS
Organization from one central monitoring account, see
[`org-observability/`](org-observability/README.md) — it adds a CloudWatch
Observability Access Manager (OAM) sink/link setup plus a `collector` +
`org-dashboard` split for each dashboard, deployed via CloudFormation
StackSets. See the "Org-wide" column in the dashboard table above for
which dashboards have this today.

## Requirements

- Security Hub and/or GuardDuty enabled in the account/region (for the security
  posture dashboard)
- Permissions to create EventBridge rules, CloudWatch Log groups, Log metric
  filters, and CloudWatch dashboards
- No QuickSight license required

## CI

GitHub Actions runs on every push/PR:
- **CloudFormation:** cfn-lint, Checkov
- **Terraform:** `terraform fmt -check`, `terraform validate`, tflint, Checkov
- **Lambda collectors and org-dashboard generators:** pytest unit tests,
  plus a script that fails the build if a dashboard's CloudFormation and
  Terraform Lambda copies have drifted apart (see [Tests](#tests) below)

The workflow follows GitHub's CI/CD hardening guidance: every action
(`checkout`, `setup-python`, `setup-terraform`, `setup-tflint`, and
`checkov-action`) is pinned to a full-length commit SHA rather than a
mutable tag or branch, with the human-readable version kept as a trailing
comment so Dependabot can still propose updates. The default
`GITHUB_TOKEN` permission is restricted to `contents: read`, checkout steps
don't persist credentials for later steps to pick up, and every job has an
explicit timeout. CI covers every CloudFormation and Terraform file in the
repo, including `org-observability/` and each dashboard's nested
`collector/`/`org-dashboard/` subfolders, not just the top-level
`cloudformation/` and `terraform/` directories. See
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) and
[`.github/dependabot.yml`](.github/dependabot.yml).

## Tests

Each dashboard's Lambda collector ships as two independent copies of the
same Python — an inline `ZipFile` in the CloudFormation template, and a
standalone `.py` file zipped by Terraform's `archive` provider — because
CFN has no packaging step and needs the code inline. The two are kept in
sync by hand rather than built from one shared source file.

That duplication is a real risk, not just a style note: it's how
`eks-security-dashboard`'s Terraform copy ended up with a variable named
`unencrypted_or_public_clusters` for a check that has nothing to do with
encryption, while the CloudFormation copy kept the correct name. Adding
these tests also surfaced a second, unrelated bug in the same file: both
copies created their `boto3` clients at module import time instead of
inside the handler (unlike the other four collectors), which works fine
in a real Lambda invocation but crashes on `NoRegionError` the moment
anything tries to import the module in an environment with no AWS region
configured — exactly what pytest collection does in CI. Both copies now
create clients lazily inside `lambda_handler`, matching the other four
collectors. Two things guard against regressions like these happening
silently again:

- **`tests/`** — pytest unit tests for the non-trivial logic in each
  collector (stale-access-key/AMI date math, external-trust-policy
  detection, security-group/S3-exposure classification, EKS version-drift
  and public-endpoint detection). It also includes
  `tests/test_org_dashboard_generators.py`, which loads each org-dashboard's
  inline generator Lambda, drives its `handler()` in both account modes,
  and checks the dashboard it would submit: valid JSON, unique metric ids
  per widget, no overlapping widgets on the 24-column grid, CloudWatch's
  widget and metric limits, and rejection of bad account IDs and
  namespaces. It checks structure only; it can't show that a query renders
  in a real monitoring account. Run them locally with:
  ```
  pip install -r tests/requirements.txt
  pytest tests/ -v
  ```
- **`scripts/check_lambda_drift.py`** — tokenizes both copies of each
  Lambda (ignoring comments, docstrings, and formatting differences like
  line-wrapping) and fails if the underlying code doesn't match. Run it
  with `python scripts/check_lambda_drift.py` after installing `pyyaml`.

Both run in CI on every push/PR (the `lambda-tests` job).

## Known limitations

- **CFN/Terraform Lambda parity is enforced by CI, not by construction.**
  See [Tests](#tests) above — the drift checker catches a mismatch, it
  doesn't prevent one from being written in the first place.
- **Dashboards are read-only observability, not remediation.** Nothing
  here opens a PR, revokes a key, or closes a security group on your
  behalf — that's a deliberate scope boundary, not a missing feature.
- **Org-wide deployment assumes StackSets access to every member
  account**, which some locked-down or FedRAMP-boundary AWS Organizations
  restrict. If that's your environment, expect to adapt the org-dashboard
  deployment step rather than run it as-is.
- **Org-dashboards default to an "all accounts" mode that has not been
  verified.** With no account list, each org-dashboard uses CloudWatch
  Metrics Insights queries (`GROUP BY AWS.AccountId` where a breakdown is
  shown) over every account linked to the monitoring account, so there is
  no per-widget account ceiling. Queries return at most 500 time series,
  so per-account breakdowns truncate in very large orgs (totals don't),
  and totals are sums over the period, which assumes each collector
  publishes at most once per period (the default is daily). Log panels
  (security-posture, network-exposure, eks-security) can't be queried this
  way, so they are per-account and driven by a separate log account list.
- **An explicit account list is still supported** and behaves as before:
  one metric per account per series, so a widget with S series supports
  roughly 500/(S+1) accounts (CloudWatch allows 500 metrics per widget and
  500 widgets per dashboard). Use it to restrict a dashboard to specific
  accounts, or split a very large org across several dashboards.
- **The org-dashboards have not been deployed to a live AWS Organization.**
  They are linted, validated, and their generated dashboard bodies are
  checked structurally in CI-equivalent runs, but cross-account rendering
  (OAM-linked metrics, Metrics Insights queries, and log widgets) needs a
  real org to confirm.

## Proof

Two dashboards deployed for real, two real bugs found:
`security-posture-dashboard` and `eks-security-dashboard`'s shared
EventBridge -> CloudWatch Logs resource policy never actually authorized
the call CloudWatch Logs makes, so neither had ever received data, in
either IaC flavor; and `eks-security-dashboard`'s Lambda hit a separate,
hardcoded-concurrency bug shared by all five other Lambda-collector
dashboards. Both fixed everywhere they appeared. The other six dashboards
were confirmed not to share bug #1, and got bug #2's fix applied, but were
not independently deployed. See [`docs/PROOF.md`](docs/PROOF.md) for the
exact test status of each dashboard.

## License

MIT — see [LICENSE](LICENSE)
