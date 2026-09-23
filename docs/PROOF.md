# Proof that these dashboards work

Run for real across four sessions (**2026-09-22 and 2026-09-23**) against a
real AWS account: every dashboard with custom Lambda/EventBridge logic has
now been deployed via `terraform apply` (and, for `security-posture-dashboard`,
also via `aws cloudformation create-stack`) and had its collector invoked
directly against real AWS APIs, not just planned or left to a daily
schedule. Verified against AWS's own records (`describe-log-streams`,
`get-query-results`, `get-metric-statistics`, `list-metrics`,
`describe-resource-policies`, direct Lambda `invoke`, an EventBridge
dead-letter queue, CloudWatch Logs) rather than only the tools' own output.
Account IDs are masked below and in the evidence files.

**Two independent, real bugs were found and fixed** in the first two
dashboards deployed, each shared by every other dashboard using the same
pattern - see section 2. **A third issue turned up doing the CloudFormation
smoke test**: not a functional bug, but an incorrect assumption in the
earlier fix that produced a harmless-but-wrong redundant wildcard, corrected
once found. See section 2 for that too.

## Test status by dashboard

| Dashboard | Live-deployed | CFN also deployed | Collector invoked & verified | Real findings/data confirmed |
|---|---|---|---|---|
| `security-posture-dashboard` | **Yes** (x3 Terraform - its own proof, redeployed for fedramp-20x-audit, redeployed again post-CFN-fix) | **Yes** (x2 - found and fixed the redundant-wildcard issue, then reverified) | N/A (event-driven, not a scheduled collector) | Synthetic + real GuardDuty findings, metrics, Logs Insights queries |
| `eks-security-dashboard` | **Yes** (Terraform) | No - CFN got the same code correction (untested-in-isolation, but the identical pattern already reverified via `security-posture-dashboard`'s CFN deployment) | **Yes** - `patch_check` Lambda invoked directly | 0 EKS clusters (accurate - none exist), all 6 metrics published |
| `network-exposure-dashboard` | **Yes** (Terraform) | No | **Yes** - invoked directly | 0 exposure findings (accurate), 85 metrics published |
| `nhi-governance-dashboard` | **Yes** (Terraform) | No | **Yes** - invoked directly | 6 real findings (2 genuine external-trust IAM roles), 26 metrics published |
| `bedrock-usage-cost-dashboard` | **Yes** (Terraform) | No | **Yes** - invoked directly | $0.00 real cost (accurate - no Bedrock usage), 1 metric published |
| `ai-service-inventory-dashboard` | **Yes** (Terraform) | No | **Yes** - invoked directly | 102 metrics published across 17 regions |
| `fedramp-20x-audit-dashboard` | **Yes** (Terraform) | No | **Yes** - invoked directly (see the false-alarm note in section 2) | 161 real findings across 17 regions, 35 metrics published, correctly distinguished the one region with Security Hub/GuardDuty enabled from the 16 without |
| `agentic-ai-guardrails-dashboard` | Not deployed | No | N/A - no custom code | Reads Bedrock's native CloudWatch metrics directly; nothing here for a collector-style test to exercise beyond what `terraform validate`/`cfn-lint` already cover |

Every dashboard with custom logic has now been live-tested via Terraform.
The one exception has none to test. CloudFormation itself was smoke-tested
once (`security-posture-dashboard`) rather than for every dashboard - see
section 3.

## 1. Claims and evidence

| # | Claim | Result | Evidence |
|---|---|---|---|
| 1 | A Security Hub finding flows EventBridge -> CloudWatch Logs -> metric filter -> CloudWatch metric (`security-posture-dashboard`) | **Disproven, then proven after a fix** | [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json) |
| 2 | `eks-security-dashboard`'s resource-policy fix deployed correctly, and its scheduled Lambda runs and publishes metrics | **Proven** | [`eks-security-dashboard-deployment.json`](proof/eks-security-dashboard-deployment.json) |
| 3 | The reserved-concurrency bug is real and account-quota-dependent | **Proven, then fixed** | [`reserved-concurrency-bug.json`](proof/reserved-concurrency-bug.json) |
| 4 | `network-exposure-dashboard`'s collector runs cleanly against a real account with no exposure issues | **Proven** | [`remaining-collectors-deployment.json`](proof/remaining-collectors-deployment.json) |
| 5 | `nhi-governance-dashboard`'s collector finds real, accurate IAM governance issues, not false positives | **Proven** | Same file - 2 genuine external-trust roles correctly identified by name |
| 6 | `bedrock-usage-cost-dashboard`'s collector correctly reports zero cost/usage when there is none | **Proven** | Same file |
| 7 | `ai-service-inventory-dashboard`'s multi-region scan runs to completion and publishes one metric set per region | **Proven** | Same file - 102 metrics across 17 regions |
| 8 | `fedramp-20x-audit-dashboard`'s collector correctly distinguishes per-region service state (not a single account-wide check) | **Proven** | [`fedramp-20x-audit-deployment.json`](proof/fedramp-20x-audit-deployment.json) - the one region with Security Hub/GuardDuty enabled produced control-level findings; the other 16 correctly produced "not enabled" findings |
| 9 | The collector Lambdas degrade gracefully when a dependent AWS service isn't available, rather than crashing | **Proven** | Same file - Trusted Advisor (no Business/Enterprise support), missing IAM password policy, and missing S3 account-level Block Public Access config were all caught and logged as findings, not unhandled exceptions |
| 10 | Teardown removes everything, across all six dashboards deployed in this proof | **Proven** | `terraform destroy` on each: 13-21 destroyed, 0 remaining, in every case |
| 11 | `security-posture-dashboard`'s CloudFormation template deploys cleanly via `aws cloudformation create-stack`, independent of Terraform | **Proven** | [`cfn-smoke-test.json`](proof/cfn-smoke-test.json): `CREATE_COMPLETE`, all 13 resources created |
| 12 | CloudFormation's `Fn::GetAtt LogGroup.Arn` already includes a trailing `:*`, unlike Terraform's `.arn` attribute - a real, previously-undocumented divergence between the two IaC tools for the same resource | **Proven** | Same file: an isolated one-resource probe stack's `Fn::GetAtt` output confirmed this directly, independent of any other code |
| 13 | The earlier CFN "fix" for bug #1 was actually unnecessary (CFN was likely never broken) and produced a harmless-but-wrong redundant wildcard | **Proven, then corrected** | Same file: the deployed policy showed `:*:*` before the correction and a clean single `:*` after; delivery worked in both cases, confirmed by resubmitting a synthetic finding after the correction |

## 2. What running it for real found

**Bug #1** (found deploying `security-posture-dashboard`): every
`AWS::Logs::ResourcePolicy` / `aws_cloudwatch_log_resource_policy` in this
repo granted `logs:PutLogEvents`/`logs:CreateLogStream` on the bare
log-group ARN, which CloudWatch Logs never actually authorizes (it checks
against the log *stream*, not the group). Fixed in all 8 places it appeared
(`security-posture-dashboard` and `eks-security-dashboard`, Terraform +
CloudFormation, main + collector). Full details in the PR history and
[`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json).

**Bug #2** (found deploying `eks-security-dashboard`, immediately after
fixing bug #1): every Lambda-collector dashboard in this repo hardcodes
`reserved_concurrent_executions = 1`, which fails outright in any account
at AWS's minimum required unreserved concurrency (10) - a normal
fresh-account default. Fixed in all 24 places it appeared (6 dashboards x
{Terraform main, Terraform collector, CloudFormation template,
CloudFormation collector}), with an `enable_lambda_reserved_concurrency`
toggle. Verified by redeploying every affected dashboard with the toggle
off and invoking each collector directly - see the status table above.

**Issue #3** (found doing the CloudFormation smoke test of
`security-posture-dashboard`, after bugs #1 and #2 were both already fixed):
the CFN version of the bug #1 fix was itself wrong, though harmlessly. The
original fix (PR #26) assumed `Fn::GetAtt LogGroup.Arn` behaves the same in
CloudFormation as `aws_cloudwatch_log_group.arn` does in Terraform (a bare
ARN with no trailing `:*`), and appended `:*` accordingly. In fact
CloudFormation's `Fn::GetAtt` on this attribute *already* returns the ARN
with a trailing `:*` - confirmed directly by deploying an isolated
one-resource probe stack and reading the value back, independent of any of
this repo's other code. The appended fix therefore produced a redundant
`:*:*`, which happened to still authorize delivery (verified: a synthetic
finding reached the log group with the double wildcard in place) but was
never correct. Corrected in all 8 places the redundant `:*` had been added
(the same 4 CFN files from bug #1's fix), reverting to the bare
`Fn::GetAtt` reference and updating each comment to explain the actual
CFN-vs-Terraform divergence. Reverified after the correction: the resource
policy now shows a single `:*`, and a second synthetic finding still
reached the log group. See
[`cfn-smoke-test.json`](proof/cfn-smoke-test.json).

**A false alarm worth recording as its own finding** (`fedramp-20x-audit-dashboard`):
the first attempt to invoke its collector appeared to fail with a "Read
timeout" error. This was the AWS CLI's own client-side timeout, not a
Lambda failure - the Lambda's CloudWatch Logs showed a clean 107-second
run with no exception. Recorded in
[`fedramp-20x-audit-deployment.json`](proof/fedramp-20x-audit-deployment.json)
because it's exactly the kind of thing worth being explicit about having
chased down, rather than either (a) reporting a bug that wasn't one, or
(b) silently retrying and not mentioning the confusion at all.

## 3. What this does not prove

- **`agentic-ai-guardrails-dashboard`.** Not deployed. It has no custom Lambda or EventBridge logic to invoke - it's a CloudWatch Dashboard resource reading Bedrock's own native metric namespaces directly. `terraform validate`/`cfn-lint` cover its only failure mode (malformed widget JSON); there is no collector to run against real AWS and no bug class analogous to bugs #1/#2 that could hide in it.
- **`eks-security-dashboard`'s GuardDuty EKS Protection and Inspector v2 findings.** Could not be triggered end-to-end via any safe synthetic method - `create-sample-findings` never fires the native GuardDuty EventBridge event, and `events put-events` refuses to spoof either `aws.guardduty` or `aws.inspector2` as a source. What's proven is that the resource-policy fix deployed correctly (API-verified); not that a live finding from either service was actually delivered.
- **The org-wide, multi-account collector path** (`org-observability/`, OAM sink/link, StackSets) for any dashboard. Every collector module's resource policy and concurrency setting were fixed alongside the single-account version, but no org-dashboard's cross-account aggregation was deployed or exercised.
- **The CloudFormation templates, beyond the one smoke test.** `security-posture-dashboard`'s CFN template was deployed for real and verified end-to-end (see issue #3 above, and claims 11-13). The other five CFN templates (`eks-security-dashboard` and the five Lambda-collector dashboards) received the identical code fixes for bugs #1/#2 - and, for the two that had it, the same redundant-wildcard correction - but were not themselves deployed. Given the CFN smoke test found a real divergence from Terraform in this exact area (`Fn::GetAtt` behavior) that code review alone hadn't caught, that gap is worth taking seriously rather than assuming "one CFN template worked, so they all do."
- **Multi-region deployment.** Every dashboard's own resources were deployed in `us-east-1` only, even though several of their collectors *scan* multiple regions from that single deployment.
- **The actual rendered CloudWatch Dashboard widgets** (as opposed to the metrics and log data feeding them) were not visually inspected in a browser for any dashboard - only the underlying data was confirmed to exist and be well-formed.
- **Cost.** Real GuardDuty/Security Hub/Lambda/CloudWatch Logs/Metrics/SQS/KMS charges accrued for roughly the time each dashboard was live across all these runs; not measured.
- **A minor, unresolved cleanup side effect:** several synthetic Security Hub findings from earlier testing (in this account, not created by any dashboard here) could not be archived or resolved before Security Hub was disabled again at the end of this proof. Harmless, and unrelated to any dashboard's correctness, but left as a known loose end rather than a claimed-complete cleanup.

## 4. Reproduce it

**Bug #1 (EventBridge -> Logs delivery)** and **bug #2 (reserved
concurrency)**: see the reproduce steps already in this file's history and
in [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json) /
[`reserved-concurrency-bug.json`](proof/reserved-concurrency-bug.json).

**Any Lambda-collector dashboard**, once deployed with
`enable_lambda_reserved_concurrency = false` in a low-quota account:

1. `aws lambda invoke --function-name <collector-name> --cli-binary-format raw-in-base64-out output.json` - use a generous `--cli-read-timeout` (120s+) for `fedramp-20x-audit-collector` specifically; its 15-minute Lambda timeout reflects a genuinely long multi-region, multi-service scan, and the CLI's own default read timeout can trip before the Lambda actually finishes. If a "Read timeout" happens, check the Lambda's own CloudWatch Logs for a clean `END`/`REPORT` line before concluding it actually failed.
2. Read the JSON response body - each collector reports its own `metrics_published`/`findings` counts.
3. `aws cloudwatch list-metrics --namespace <NamespaceName>` and confirm the count matches.
4. For a deeper check, read the Lambda's own CloudWatch Logs for the specific findings it reported, and spot-check a few against what you know to be true about the account (e.g., a role you know has a cross-account trust, or a service you know isn't enabled in a given region).

**Issue #3 (CFN `Fn::GetAtt` trailing wildcard):** deploy a one-resource
stack with just an `AWS::Logs::LogGroup` and an `Output` of
`!GetAtt <name>.Arn`; the value comes back with a trailing `:*` already
present. Compare against Terraform's `aws_cloudwatch_log_group.<name>.arn`
for the same underlying resource, which does not include it.

`docs/proof/` holds the machine-readable evidence from every run above.
