# Proof that these dashboards work

Run for real on **2026-09-22 and 2026-09-23** against a real AWS account
with Security Hub and GuardDuty enabled: two of the eight dashboards were
deployed via `terraform apply` and fed real and schema-accurate synthetic
events through their real EventBridge -> Logs -> metric-filter -> dashboard
pipelines; the remaining six were audited for the same defect class by
reading every `main.tf` and `template.yaml` in the repo. Verified against
AWS's own records (`describe-log-streams`, `get-query-results`,
`get-metric-statistics`, `describe-resource-policies`, a direct Lambda
`invoke`, an EventBridge dead-letter queue) rather than only the tools' own
output. Account IDs are masked below and in the evidence files.

**Neither deployed dashboard worked at all, at first** - two independent,
real bugs, one shared by every dashboard using a given pattern. See section 2.

## Test status by dashboard

| Dashboard | Uses the EventBridge->Logs pattern (bug #1)? | Uses a Lambda collector (bug #2)? | Live-deployed & verified in this repo's history | Status |
|---|---|---|---|---|
| `security-posture-dashboard` | Yes | No | **Yes** (Terraform) | Bug #1 found, fixed, verified against real data |
| `eks-security-dashboard` | Yes (2 rules) | Yes | **Yes** (Terraform) | Bug #1 fix confirmed deployed correctly (API-verified); bug #2 found, fixed, verified via direct Lambda invoke + published metrics |
| `bedrock-usage-cost-dashboard` | No | Yes | No | Bug #2 fix applied (same pattern); not independently deployed |
| `ai-service-inventory-dashboard` | No | Yes | No | Bug #2 fix applied (same pattern); not independently deployed |
| `network-exposure-dashboard` | No | Yes | No | Bug #2 fix applied (same pattern); not independently deployed |
| `nhi-governance-dashboard` | No | Yes | No | Bug #2 fix applied (same pattern); not independently deployed |
| `fedramp-20x-audit-dashboard` | No | Yes | No | Bug #2 fix applied (same pattern); not independently deployed |
| `agentic-ai-guardrails-dashboard` | No | No | No | No EventBridge routing at all - reads Bedrock's native CloudWatch metrics directly; neither bug applies |

"Fix applied (same pattern), not independently deployed" means: found by grep
across the whole repo once discovered in a deployed dashboard, fixed with
the identical code change, and confirmed with `terraform validate`/`fmt`,
`cfn-lint`, and Checkov - but that specific dashboard's own Lambda was not
itself invoked against real AWS to confirm the fix resolves the failure
there too. Section 3 is explicit about this gap.

## 1. Claims and evidence

| # | Claim | Result | Evidence |
|---|---|---|---|
| 1 | A Security Hub finding flows EventBridge -> CloudWatch Logs -> metric filter -> CloudWatch metric (`security-posture-dashboard`) | **Disproven, then proven after a fix** | [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json): 0 log streams, `FailedInvocations=1` on every attempt before the fix; 1 log stream and a real metric datapoint after |
| 2 | The dashboard's own Logs Insights queries ("by severity", "top failing controls") return correct results against real log data | **Proven, after the fix** | Same file: both queries returned the exact severity label and `GeneratorId` of the synthetic finding submitted |
| 3 | KMS encryption on the log groups is not what was blocking delivery | **Proven** | Reproduced the failure with the log group's KMS key fully disassociated - same `NO_PERMISSIONS` failure |
| 4 | The failure isn't propagation delay or a stray SCP | **Proven** | Reproduced on a brand-new, fully isolated log group/rule/policy triplet, retried after a 3-minute wait; confirmed no custom SCP is attached to this account or its OU |
| 5 | `eks-security-dashboard`'s two resource policies got the identical fix, correctly, in the real deployed stack | **Proven** | [`eks-security-dashboard-deployment.json`](proof/eks-security-dashboard-deployment.json): `aws logs describe-resource-policies` shows both `Resource` ARNs ending in `:*` as deployed |
| 6 | `eks-security-dashboard`'s scheduled Lambda (`patch_check`) runs correctly and publishes its metrics | **Proven** | Same file: direct `invoke` returned `StatusCode 200` with a well-formed body; all 6 `EKS/Security` namespace metrics confirmed present via `list-metrics` |
| 7 | The reserved-concurrency bug (found while deploying `eks-security-dashboard`) is real and account-quota-dependent, not test-account-specific | **Proven** | [`reserved-concurrency-bug.json`](proof/reserved-concurrency-bug.json): this account's real Lambda concurrency limit is 10 (a normal fresh-account default), and reserving even 1 unit fails deployment outright |
| 8 | The other five Lambda-collector dashboards don't use the EventBridge->Logs pattern at all | **Proven** | Grep across every `main.tf`/`template.yaml` in the repo: zero `AWS::Logs::ResourcePolicy`/`aws_cloudwatch_log_resource_policy` outside the two already fixed |
| 9 | Teardown removes everything for both deployed dashboards | **Proven** | `terraform destroy`: 13 destroyed (security-posture) + 21 destroyed (eks-security), 0 remaining in both cases |

## 2. What running it for real found

**Bug #1 - the core delivery mechanism this repo describes as its shared
pattern never worked, in either dashboard that uses it.** Not caught by
`cfn-lint`, `terraform validate`, tflint, or Checkov, because the resource
policy is syntactically and semantically valid IAM - it just doesn't
authorize the actual call CloudWatch Logs makes.

| Found | By | Fixed |
|---|---|---|
| Every `AWS::Logs::ResourcePolicy` / `aws_cloudwatch_log_resource_policy` in this repo granted `logs:PutLogEvents`/`logs:CreateLogStream` on the bare log-group ARN. CloudWatch Logs authorizes those actions against the log *stream*, which doesn't exist until the first successful write - so the policy's `Resource` never matched, and delivery failed 100% of the time with EventBridge's generic `ERROR_CODE: NO_PERMISSIONS`, visible only via a dead-letter queue you'd have to think to attach | A DLQ attached to the failing target, after ruling out KMS, propagation delay, and SCPs | Appended `:*` to every affected `Resource` ARN, in all 8 places it appeared: `security-posture-dashboard` and `eks-security-dashboard`, each in Terraform (main + collector) and CloudFormation (template + collector) |

This means **`security-posture-dashboard` and `eks-security-dashboard` had
never actually received data**, in either IaC flavor, in either the
single-account or org-wide-collector variant.

**Audited (not deployed) the other six dashboards for the same pattern
afterward:** none of them use it. `agentic-ai-guardrails-dashboard` has no
EventBridge routing at all - it reads native Bedrock/Guardrails CloudWatch
metrics directly. The remaining five (`bedrock-usage-cost`,
`ai-service-inventory`, `network-exposure`, `nhi-governance`,
`fedramp-20x-audit`) route through a scheduled EventBridge rule invoking a
Lambda collector, authorized via `aws_lambda_permission` - a different,
correct mechanism unaffected by bug #1.

**Bug #2 - found independently while deploying `eks-security-dashboard`,**
whose scheduled Lambda hit an entirely different failure than bug #1:

| Found | By | Fixed |
|---|---|---|
| Every Lambda-collector dashboard in this repo hardcodes `reserved_concurrent_executions = 1` (Terraform) / `ReservedConcurrentExecutions: 1` (CloudFormation), assuming an account with the standard 1,000-execution concurrency quota. This test account's real limit is 10 - a normal fresh-account default - so reserving even 1 unit fails: `decreases account's UnreservedConcurrentExecution below its minimum value of [10]` | The very next `terraform apply` after fixing bug #1, deploying `eks-security-dashboard` | Added an `enable_lambda_reserved_concurrency` toggle (Terraform variable / CloudFormation parameter, default `true` to preserve existing behavior) to all 24 places the hardcoded value appeared: 6 dashboards x {Terraform main, Terraform collector, CloudFormation template, CloudFormation collector}. See [`reserved-concurrency-bug.json`](proof/reserved-concurrency-bug.json) |

This is the identical bug already found and fixed once this session in the
sibling `aws-remediation-orchestrator` repo - same account-quota assumption,
same fix shape. Only `eks-security-dashboard`'s own instance was redeployed
and confirmed fixed against real AWS (Lambda invoked, metrics published);
the other five dashboards got the identical code change but were not
independently redeployed - see the status table above and section 3.

## 3. What this does not prove

- **`bedrock-usage-cost`, `ai-service-inventory`, `network-exposure`, `nhi-governance`, `fedramp-20x-audit` were never live-deployed at all**, before or after either fix. Their Lambda collectors' own IAM permissions, API calls, and metric/query logic are completely unverified by this proof - only that they don't share bug #1, and that bug #2's fix compiles/validates/lints cleanly for them too.
- **`eks-security-dashboard`'s GuardDuty EKS Protection and Inspector v2 findings could not be exercised end-to-end.** GuardDuty's `create-sample-findings` never triggers the native `aws.guardduty`/`GuardDuty Finding` EventBridge event (confirmed generally in this proof's security-posture-dashboard work, not EKS-specific), and `events put-events` refuses to spoof either `Source: aws.guardduty` or `Source: aws.inspector2` (`NotAuthorizedForSourceException`, confirmed for both). There is no synthetic-finding mechanism for Inspector v2 at all. What *is* proven is that the identical resource-policy fix was deployed correctly (API-verified) and that the fix's general mechanism was already conclusively proven on a fully isolated test rig unrelated to any specific dashboard - not that a live finding from either service was actually delivered here.
- **The org-wide, multi-account collector path** (`org-observability/`, OAM sink/link, StackSets) for any dashboard. Every collector module's resource policy was fixed alongside its single-account counterpart (same bug), but no org-dashboard's cross-account aggregation was deployed or exercised.
- **The CloudFormation templates**, fixed with the identical changes as their Terraform counterparts, were not themselves deployed for either bug - only the Terraform modules were applied and verified against real AWS behavior. The CFN fix rests on the CFN and Terraform versions being genuinely identical, as the repo's README claims.
- **Multi-region.** Tested in `us-east-1` only.
- **Cost.** Real GuardDuty/Security Hub/Lambda/CloudWatch Logs/Metrics charges accrued for roughly the time each dashboard was live; not measured.

## 4. Reproduce it

**Bug #1 (EventBridge -> Logs delivery):**

1. Deploy `security-posture-dashboard` or `eks-security-dashboard` (Terraform) with Security Hub/GuardDuty enabled.
2. `aws securityhub batch-import-findings` with a synthetic ASFF finding under your own account's default product ARN (`arn:aws:securityhub:<region>:<account>:product/<account>/default`) - see the finding shape in [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json).
3. `aws cloudwatch get-metric-statistics --namespace AWS/Events --metric-name FailedInvocations --dimensions Name=RuleName,Value=<rule-name>` - on the unfixed module, expect `Sum: 1` for every invocation.
4. To see the actual reason: attach a temporary SQS queue as the target's `DeadLetterConfig` and re-submit; `aws sqs receive-message --message-attribute-names All` shows `ERROR_CODE: NO_PERMISSIONS`.
5. On the fixed module, repeat step 2 and confirm `aws logs describe-log-streams` shows a stream.

**Bug #2 (reserved concurrency):**

1. Check your account's real limit: `aws lambda get-account-settings --query AccountLimit`.
2. If `ConcurrentExecutions` is low (a fresh account may show 10), deploy any Lambda-collector dashboard with the default `enable_lambda_reserved_concurrency = true` and watch `terraform apply` fail with `decreases account's UnreservedConcurrentExecution below its minimum value`.
3. Set `enable_lambda_reserved_concurrency = false` and redeploy; confirm the Lambda deploys, `aws lambda invoke` returns `StatusCode 200`, and its metrics appear via `aws cloudwatch list-metrics`.

`docs/proof/` holds the machine-readable evidence from both runs above.
