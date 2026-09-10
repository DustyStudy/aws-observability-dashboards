# fedramp-20x-audit-dashboard (CloudFormation)

A continuous-audit-evidence dashboard for teams pursuing (or maintaining)
**FedRAMP 20x** authorization on AWS. FedRAMP 20x replaces the old
narrative-control assessment model with **Key Security Indicators (KSIs)** —
machine-verifiable outcomes an assessor expects to see evidenced by live
telemetry, not a written description ("produce telemetry showing MFA is
enforced," not "describe how you enforce MFA"). This dashboard exists to
give you that telemetry in one place, continuously, instead of screenshotting
consoles the week before an assessment.

It does this two ways:

1. **A new Lambda** (this folder) checks AWS Config recorder/rule
   compliance, CloudTrail health, AWS Backup plan coverage and job outcomes,
   IAM Access Analyzer external-access findings, RDS/ASG availability-zone
   posture, Config auto-remediation coverage, VPC endpoint/NACL posture,
   ACM certificate expiry, S3 secure-transport policies, a Security Hub
   pass/fail score, account-wide Inspector findings (not just EKS/ECR), EC2
   instance-profile coverage, and Trusted Advisor security-check status
   where the support plan allows it — 26 metrics across 12 AWS services,
   none of which the other six dashboards in this repo already cover.
2. **Reuses the other dashboards' existing metrics.** MFA/stale-credential
   checks, open security groups and public-facing resources, and Security
   Hub/GuardDuty finding *counts* are already collected by
   [`nhi-governance-dashboard`](../nhi-governance-dashboard),
   [`network-exposure-dashboard`](../network-exposure-dashboard), and
   [`security-posture-dashboard`](../security-posture-dashboard). This
   dashboard's widgets read those namespaces directly rather than scanning
   the same things twice.

Every widget title includes the specific KSI ID it evidences (e.g.
`KSI-MLA-EVC`), so in an assessment you can point at a widget and say
exactly which indicator it supports. See [KSI mapping](#ksi-mapping) below
for the complete list, including what this dashboard **doesn't** cover and
why.

## Prerequisites

Deploy these three dashboards in the same account(s) **first** — this
dashboard's widgets will render with no data (not an error, just empty)
until their metrics exist:

- [`nhi-governance-dashboard`](../nhi-governance-dashboard)
- [`network-exposure-dashboard`](../network-exposure-dashboard)
- [`security-posture-dashboard`](../security-posture-dashboard)

Also required:

- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch
  dashboard
- The collector's role needs read-only access across sixteen services —
  Config (`config:Describe*`), CloudTrail (`cloudtrail:DescribeTrails`,
  `cloudtrail:GetTrailStatus`), Backup (`backup:List*`), Access Analyzer
  (`access-analyzer:List*`), RDS (`rds:DescribeDBInstances`), Auto Scaling
  (`autoscaling:DescribeAutoScalingGroups`), EC2 (`ec2:DescribeVpc*`,
  `ec2:DescribeNetworkAcls`, `ec2:DescribeInstances`,
  `ec2:GetEbsEncryptionByDefault`, `ec2:DescribeRegions`), ACM
  (`acm:ListCertificates`,
  `acm:DescribeCertificate`), S3 (`s3:ListAllMyBuckets`,
  `s3:GetBucketPolicy`, `s3:GetAccountPublicAccessBlock`), Security Hub
  (`securityhub:GetFindings`, `securityhub:DescribeHub`), Inspector
  (`inspector2:ListFindings`, `inspector2:BatchGetAccountStatus`), Support
  (`support:DescribeTrustedAdvisor*`), GuardDuty (`guardduty:ListDetectors`,
  `guardduty:GetDetector`), IAM (`iam:GetAccountPasswordPolicy`), and STS
  (`sts:GetCallerIdentity`) — none of it modifies or deletes anything
- AWS Config, an active CloudTrail, at least one AWS Backup plan, and an
  active IAM Access Analyzer are assumed to *exist* — if any of these
  services isn't enabled in the account, the corresponding metrics report as
  `0`/non-compliant rather than erroring, which is itself useful signal
  (KSI-MLA-EVC and KSI-MLA-OSM specifically expect these to be running)
- **Trusted Advisor security checks require a Business or Enterprise
  support plan.** On Basic/Developer support, `TrustedAdvisorAvailable`
  reports `0` rather than erroring — also useful signal, since an assessor
  may ask why it's unavailable
- The collector scans **every enabled region in the account**, not just
  where the Lambda itself runs — see [Known limitations](#known-limitations)
  for exactly how results get combined across regions. The Lambda's timeout
  is 900s/1024MB by default (900s is Lambda's own ceiling) to give a
  multi-region, multi-service scan enough headroom; the collector logs
  which check is running in which region so a timeout is easy to attribute

No QuickSight license required.

## Deploy — single account

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name fedramp-20x-audit-dashboard \
  --parameter-overrides \
      NamePrefix=fedramp-20x-audit \
      NhiGovernanceNamespace=NHIGovernance \
      NetworkExposureNamespace=NetworkExposure \
      SecurityObservabilityNamespace=SecurityObservability \
  --capabilities CAPABILITY_NAMED_IAM
```

The three namespace parameters must match whatever `MetricNamespace` you
used when deploying the other three dashboards — the defaults line up if
you didn't override theirs either.

## Deploy — org-wide

1. Deploy `collector.yaml` (this folder) via StackSets to every member
   account, alongside the collectors for the three prerequisite dashboards.
2. Deploy `org-dashboard.yaml` once, in your central monitoring account —
   see [`../../org-observability/README.md`](../../org-observability/README.md)
   for the OAM Sink/Link setup this depends on.

`CAPABILITY_NAMED_IAM` is required because these stacks create named IAM
roles.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `fedramp-20x-audit` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `FedRAMP20xAudit` | Namespace this stack's own collector publishes into |
| `AuditScanSchedule` | `rate(1 day)` | How often the scan runs |
| `NhiGovernanceNamespace` | `NHIGovernance` | Must match nhi-governance-dashboard's `MetricNamespace` |
| `NetworkExposureNamespace` | `NetworkExposure` | Must match network-exposure-dashboard's `MetricNamespace` |
| `SecurityObservabilityNamespace` | `SecurityObservability` | Must match security-posture-dashboard's `MetricNamespace` |

## Outputs

- `AuditCollectorFunctionName` / `AuditCollectorLogGroupName` — the new
  collector's own logs, where flagged resource IDs (non-compliant rule
  names, failed backup job ARNs, Access Analyzer finding resources) are
  printed, since metrics only carry numbers

## KSI mapping

FedRAMP 20x Class B (Low) defines KSIs across nine clusters. The table
below covers every KSI a widget on this dashboard evidences, either
directly (this stack's own metrics) or by reading another dashboard's
existing metrics.

| KSI ID | What it requires | Evidenced by |
|---|---|---|
| KSI-MLA-EVC | Configuration of resources is persistently evaluated | Config Rules Compliant/Non-Compliant widgets |
| KSI-SVC-ACM | Configuration is automated and reviewed for drift | Config Rules Compliant/Non-Compliant widgets |
| KSI-MLA-OSM | A SIEM/logging system centrally, tamper-resistantly logs activity | CloudTrail Healthy widget (multi-region + logging active) |
| KSI-MLA-LET | A list of logged resources/event types is maintained and enforced | CloudTrail Healthy widget |
| KSI-CMT-LMC | Modifications to the service are logged and monitored | CloudTrail Healthy widget |
| KSI-SVC-VRI | Cryptographic methods validate resource integrity | CloudTrail log file validation status (rolled into the Healthy widget) |
| KSI-RPL-ABO | Backups are aligned with recovery objectives | Backup Plans Count widget |
| KSI-RPL-TRC | Recovery capability is persistently tested | Backup Jobs Succeeded/Failed widgets |
| KSI-IAM-SUS | Privileged access is secured in response to suspicious activity | Access Analyzer External-Access Findings widget |
| KSI-CNA-MAT | Attack surface and lateral-movement risk are minimized | Access Analyzer findings + network-exposure-dashboard's public-resource widgets |
| KSI-IAM-APM | Passwordless/phishing-resistant MFA is used | nhi-governance-dashboard's Users Without MFA metric |
| KSI-IAM-ELP | Least privilege is enforced and reviewed | nhi-governance-dashboard's Stale IAM Roles metric |
| KSI-IAM-JIT | A least-privileged, JIT authorization model is used and reviewed | nhi-governance-dashboard's External-Trust Roles metric |
| KSI-SVC-ASM | Secret management and rotation are automated | nhi-governance-dashboard's Secrets Without Rotation metric |
| KSI-CNA-RNT | Network traffic is restricted to what's needed | network-exposure-dashboard's Open Security Group Rules metric |
| KSI-SVC-SIN | Information is encrypted/secured from unwanted access | network-exposure-dashboard's public S3/RDS/LB widgets |
| KSI-MLA-RVL | Logs are persistently reviewed and audited | security-posture-dashboard's Security Hub/GuardDuty finding-count metrics |
| KSI-CNA-OFA | Resources are optimized for high availability and rapid recovery | RDS Instances Not Multi-AZ + Auto Scaling Groups in a Single AZ widgets |
| KSI-CNA-EIS | Non-compliant resources are automatically brought back to their intended state | Config Rules With/Without Auto-Remediation widgets |
| KSI-CNA-ULN | Logical networking is used and reviewed to enforce traffic flow controls | VPC Endpoints Count + VPCs Relying on Default NACL Only widgets |
| KSI-SVC-VCM | The authenticity/integrity of communications is validated | ACM Certificates Expiring widget + S3 Buckets Without Secure-Transport Policy widget |
| KSI-SVC-EIS | Opportunities to improve security are persistently evaluated and made | Security Hub Standards Score (% controls passed) widget |
| KSI-SCR-MON | Upstream vulnerabilities are persistently monitored | Inspector Findings, Account-Wide widget (Critical/High severity, all resource types — not just EKS/ECR) |
| KSI-IAM-SNU | Appropriately secure authentication is used for non-user accounts/services | EC2 Instances Without Instance Profile widget |
| KSI-CNA-IBP | Configuration is persistently compared against provider best-practice guidance | Trusted Advisor Checks Flagged widget (requires Business/Enterprise support — reports unavailable rather than erroring on Basic/Developer plans) |
| KSI-MLA-OSM (detector status) | The SIEM/detection capability is actually operating, not just quiet | GuardDuty + Security Hub Detectors Running widget — a finding count of zero looks identical whether an account is clean or the detector was never turned on; this closes that gap |
| KSI-SCR-MON (detector status) | Upstream vulnerability scanning is actually enabled | Inspector Scanning Enabled widget, alongside the Inspector Findings widget from the second tranche |
| KSI-SVC-SIN (account defaults) | Information is encrypted/secured by default, account-wide | EBS Encryption By Default, RDS Instances Unencrypted, and S3 Account Block Public Access Enabled widgets |
| KSI-IAM-APM (password policy) | Strong authentication requirements are enforced | IAM Password Policy Compliant widget (length ≥14, complexity, ≤90-day rotation, 24-generation reuse prevention) |
| KSI-IAM-AAM (partial) | Non-user/service account lifecycle is automated and reviewed | Inactive IAM Users widget — reuses nhi-governance-dashboard's existing metric. This shows whether stale users are accumulating, which is evidence the *review* half is happening; it doesn't prove deprovisioning itself runs through automation vs. a manual process, see below |

### What this dashboard does NOT cover, and why

FedRAMP 20x includes KSIs that are inherently procedural or narrative —
things an auditor reviews in documentation, interviews, or process
artifacts, not telemetry a CloudWatch widget can represent honestly.
Dashboarding these would mean faking a metric for something that isn't
actually one. This dashboard deliberately leaves them out rather than
manufacture a number:

- **KSI-CED-RAT** (training effectiveness), **KSI-PIY-RES** (executive
  support), **KSI-PIY-RIS** (security investment effectiveness),
  **KSI-PIY-RSD** (SDLC security review), **KSI-PIY-RVD** (vulnerability
  disclosure program review) — organizational reviews, not system state
- **KSI-CMT-RVP** (change procedure review), **KSI-INR-AAR/RIR/RPI**
  (incident after-action reports and reviews), **KSI-RPL-ARP/RRO** (recovery
  plan/objective alignment) — process artifacts, typically living in a
  ticketing system or a document, not CloudWatch
- **KSI-SCR-MIT** (supply chain risk *mitigation*, as opposed to the
  *monitoring* half above) — a risk-management process, not a single
  measurable state
- **KSI-IAM-AAM, the automation half** — the Inactive IAM Users widget
  (see table above) shows the *result* of account lifecycle hygiene, but
  not whether provisioning/deprovisioning itself runs through automation
  vs. a manual process
- **KSI-SVC-PRR** (removing residual risk after changes) and **KSI-SVC-RUD**
  (removing unwanted federal customer data on request) — both "Optional" at
  Class B, and both describe a workflow outcome tied to a specific change or
  customer request, not an always-on account state

If your organization also runs EKS, add
[`eks-security-dashboard`](../eks-security-dashboard) — its cluster/nodegroup
drift and container-image findings complement the account-wide Inspector
coverage above with EKS-specific signal (Kubernetes version drift, node AMI
staleness, public-only API endpoints).

## Known limitations

- **This is evidence aggregation, not a compliance verdict.** A FedRAMP 20x
  assessment still requires the actual assessor process (3PAO or
  self-attestation, depending on your path) — this dashboard makes the
  telemetry available and traceable to KSI IDs, it doesn't submit anything
  or replace an assessor's judgment.
- **Single-account scan by default.** For an AWS Organization, deploy
  `collector.yaml` via StackSets to every member account and use
  `org-dashboard.yaml` — see [Deploy — org-wide](#deploy--org-wide) above.
- **Namespace coupling.** The cross-dashboard widgets only work if the other
  three dashboards are deployed with matching namespace parameters. A typo'd
  namespace produces an empty widget, not an error — check the parameter
  values first if a widget looks wrong.
- **AWS Config and CloudTrail must already be enabled** for their widgets to
  mean anything; this dashboard reports their absence as a `0`/non-compliant
  signal rather than trying to enable them for you.
- **Trusted Advisor coverage requires a Business or Enterprise support
  plan.** On Basic/Developer plans, `TrustedAdvisorAvailable` reports `0`
  rather than erroring — that's itself useful signal for an assessor, but
  it means the widget won't show real data on lower support tiers.
- **The Security Hub score widget pages through every ACTIVE finding with a
  PASSED/FAILED compliance status** in the account, across every enabled
  region, to compute one account-wide percentage. On a large, multi-region
  account this can be a lot of findings — the collector's timeout was
  raised to 900s/1024MB (Lambda's own timeout ceiling) specifically to give
  this, and the rest of the multi-region scan, enough headroom.
- **Multi-region scan.** The collector calls `ec2:DescribeRegions` at the
  start of every run and loops every service check across every region the
  account is opted into — it does not just check the Lambda's own deployed
  region. "Is X enabled" metrics (Config recorder, GuardDuty, Security Hub,
  Inspector2, EBS encryption-by-default) report `1` only if **every**
  region has it enabled; a single region with it off makes the account-wide
  metric `0`. Count metrics (non-compliant rules, findings, unencrypted
  instances) are summed across all regions. CloudTrail-related metrics are
  the one exception: since a single multi-region trail covers the whole
  account, those are `1` if **any** region has a qualifying trail, not
  every region. IAM password policy and S3 account-level Block Public
  Access are checked once, since both are genuinely account-wide settings,
  not per-region ones.
- **The S3 account-level Block Public Access check needs the account's own
  ID**, resolved via one `sts:GetCallerIdentity` call per run. If that call
  fails for any reason, only that one check is skipped for the run — every
  other metric still publishes normally.
- **The detector-status checks report on/off, not health.** A GuardDuty
  detector that's enabled but hasn't ingested a CloudTrail event in months
  still reports `GuardDutyEnabled=1` — this check catches "never turned on"
  and "explicitly suspended," not silent data-source failures.

## Encryption

The audit-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Observability

The audit-collector Lambda has active AWS X-Ray tracing enabled, so a slow
or failing run shows up as a trace in the X-Ray console, not just a
CloudWatch Logs line.
