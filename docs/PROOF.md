# Proof that security-posture-dashboard works

Run for real on **2026-09-22** against a real AWS account with Security Hub
and GuardDuty enabled: deployed via `terraform apply`, fed real and
schema-accurate synthetic findings through the real EventBridge -> Logs ->
metric-filter -> dashboard pipeline, and verified against AWS's own records
(`describe-log-streams`, `get-query-results`, `get-metric-statistics`, an
EventBridge dead-letter queue) rather than only the tool's own output. The
account ID is masked below and in the evidence files.

**It didn't work at all, at first** - every single delivery from EventBridge
to CloudWatch Logs failed silently, on every dashboard in this repo that uses
this pattern, in both CloudFormation and Terraform, in both the single-account
and org-wide collector variants. See section 2.

## What was tested

| | |
|---|---|
| **Module** | `security-posture-dashboard`, Terraform variant, deployed standalone (not via the org-wide collector) |
| **Account** | One AWS account, Security Hub + GuardDuty enabled for the run, disabled again afterward |
| **Findings** | Real GuardDuty sample findings (`create-sample-findings`) for the GuardDuty-sourced-via-Security-Hub path; schema-accurate synthetic ASFF findings via `securityhub batch-import-findings` for direct, controlled testing of severity/compliance-status widgets |
| **Diagnosis** | A temporary SQS dead-letter queue attached to the failing EventBridge target, since EventBridge's `FailedInvocations` metric gives no reason on its own |

## 1. Claims and evidence

| # | Claim | Result | Evidence |
|---|---|---|---|
| 1 | A Security Hub finding flows EventBridge -> CloudWatch Logs -> metric filter -> CloudWatch metric | **Disproven, then proven after a fix** | [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json): 0 log streams, `FailedInvocations=1` on every attempt before the fix; 1 log stream and a real metric datapoint after |
| 2 | The dashboard's own Logs Insights queries ("by severity", "top failing controls") return correct results against real log data | **Proven, after the fix** | Same file: both queries returned the exact severity label and `GeneratorId` of the synthetic finding submitted |
| 3 | `severity_threshold`-style metric filters correctly parse the real ASFF event shape (`detail.findings[0].Severity.Label`) | **Proven** | `SecurityHubCriticalFindings` metric showed `Sum: 1.0` for a `Severity.Label: CRITICAL` finding |
| 4 | KMS encryption on the log groups is not what was blocking delivery | **Proven** | Reproduced the failure with the log group's KMS key fully disassociated - same `NO_PERMISSIONS` failure |
| 5 | The failure isn't propagation delay or a stray SCP | **Proven** | Reproduced on a brand-new, fully isolated log group/rule/policy triplet, retried after a 3-minute wait; confirmed no custom SCP is attached to this account or its OU |
| 6 | Teardown removes everything | **Proven** | `terraform destroy`: 13 destroyed, 0 remaining |

## 2. What running it for real found

**The core delivery mechanism this repo describes as its shared pattern -
"EventBridge rule(s) capture events... Events land in a dedicated CloudWatch
Logs group" - never worked, in any dashboard that uses it.** Not caught by
`cfn-lint`, `terraform validate`, tflint, or Checkov, because the resource
policy is syntactically and semantically valid IAM - it just doesn't
authorize the actual call CloudWatch Logs makes.

| Found | By | Fixed |
|---|---|---|
| Every `AWS::Logs::ResourcePolicy` / `aws_cloudwatch_log_resource_policy` in this repo grants `logs:PutLogEvents`/`logs:CreateLogStream` on the bare log-group ARN. CloudWatch Logs authorizes those actions against the log *stream*, which doesn't exist until the first successful write - so the policy's `Resource` never matches, and delivery fails 100% of the time with EventBridge's generic `ERROR_CODE: NO_PERMISSIONS`, visible only via a dead-letter queue you'd have to think to attach | A DLQ attached to the failing target, after ruling out KMS, propagation delay, and SCPs | Appended `:*` to every affected `Resource` ARN, in all 8 places it appears: `terraform/security-posture-dashboard/main.tf` (2 statements), `terraform/security-posture-dashboard/collector/main.tf` (2 statements), `terraform/eks-security-dashboard/main.tf` (2 resources), `terraform/eks-security-dashboard/collector/main.tf` (2 resources), and the four matching `cloudformation/*/template.yaml` / `collector.yaml` files |

This means **every dashboard in this repo that uses the EventBridge ->
CloudWatch Logs pattern has never actually received data**, in either IaC
flavor, in either the single-account or org-wide-collector variant - not
just the one this proof happened to deploy. The other six dashboards
(Bedrock, agentic AI, network exposure, NHI, AI service inventory,
FedRAMP 20x audit) were not checked for the same pattern in this pass; see
section 3.

## 3. What this does not prove

- **The GuardDuty-native half of this dashboard (and eks-security-dashboard's GuardDuty widget).** GuardDuty's `create-sample-findings` findings never trigger the native `aws.guardduty`/`GuardDuty Finding` EventBridge event - confirmed on an isolated probe - and `events put-events` refuses to let you spoof `Source: aws.guardduty` (`NotAuthorizedForSourceException`). See [`guardduty-native-event-limitation.json`](proof/guardduty-native-event-limitation.json). Only genuine (non-sample) GuardDuty findings would exercise this path.
- **The other six dashboards** (`bedrock-usage-cost`, `agentic-ai-guardrails`, `ai-service-inventory`, `network-exposure`, `nhi-governance`, `fedramp-20x-audit`) were not deployed or checked for the same resource-policy pattern in this pass. Given how systemic bug #1 was, they're worth auditing before assuming they work.
- **The org-wide, multi-account collector path** (`org-observability/`, OAM sink/link, StackSets). The collector module's own resource policy was fixed alongside the single-account one (same bug), but the org-dashboard's cross-account aggregation was not deployed or exercised here.
- **The CloudFormation templates**, fixed with the identical change, were not actually deployed in this pass - only the Terraform module was applied and verified against real AWS behavior. The CFN templates' fix rests on the CFN and Terraform versions being genuinely identical in this respect, as the repo's README claims.
- **Multi-region.** Tested in `us-east-1` only.
- **Cost.** Real GuardDuty/Security Hub/CloudWatch Logs/Metrics charges accrued for roughly the time this was live; not measured.

## 4. Reproduce it

Prerequisites: an AWS account with Security Hub and GuardDuty enabled (or
enable them as part of this).

1. `cd terraform/security-posture-dashboard && terraform init && terraform apply`.
2. `aws securityhub batch-import-findings` with a synthetic ASFF finding under your own account's default product ARN (`arn:aws:securityhub:<region>:<account>:product/<account>/default`) - see the finding shape in [`eventbridge-delivery-failure.json`](proof/eventbridge-delivery-failure.json).
3. `aws cloudwatch get-metric-statistics --namespace AWS/Events --metric-name FailedInvocations --dimensions Name=RuleName,Value=security-posture-security-hub-findings` - on the unfixed module, expect `Sum: 1` for every invocation.
4. To see the actual reason: attach a temporary SQS queue as the target's `DeadLetterConfig` (`aws sqs create-queue`, a queue policy trusting `events.amazonaws.com` scoped to the rule's ARN, then `aws events put-targets` with `DeadLetterConfig` added) and re-submit a finding; `aws sqs receive-message --message-attribute-names All` shows `ERROR_CODE: NO_PERMISSIONS`.
5. On the fixed module (this repo, post-merge), repeat step 2 and confirm: `aws logs describe-log-streams` shows a stream, and the Logs Insights queries in `main.tf`'s dashboard widgets return the finding's data when run via `aws logs start-query` / `get-query-results`.
6. `terraform destroy`, then disable GuardDuty/Security Hub if you enabled them only for this.

`docs/proof/` holds the machine-readable evidence from the run above.
