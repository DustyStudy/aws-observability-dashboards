# aws-observability-dashboards

CloudFormation and Terraform templates for CloudWatch dashboards that give cloud
security engineers visibility into security posture, AI/ML usage, and agentic AI
activity across an AWS account or org. Companion repo to
[fedramp-cfn-library](https://github.com/DustyStudy/fedramp-cfn-library),
[fedramp-terraform-library](https://github.com/DustyStudy/fedramp-terraform-library),
and [aws-cloud-security-toolbox](https://github.com/DustyStudy/aws-cloud-security-toolbox).

Every dashboard here is built on native **CloudWatch Dashboards + Logs Insights**,
not QuickSight. That's a deliberate choice for a public template repo:

- No extra licensing/per-user cost — CloudWatch is available in every account
- Works identically in AWS commercial and AWS GovCloud
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

| Dashboard | Status | Description |
|---|---|---|
| [security-posture-dashboard](cloudformation/security-posture-dashboard) | ✅ Built | Security Hub findings + GuardDuty findings — severity breakdown, top failing controls, findings by type, trend over time |
| [bedrock-usage-cost-dashboard](cloudformation/bedrock-usage-cost-dashboard) | ✅ Built | Bedrock invocations, tokens, latency, errors/throttles by model (native metrics), plus estimated daily cost by usage type via a scheduled Cost Explorer collector |
| [agentic-ai-guardrails-dashboard](cloudformation/agentic-ai-guardrails-dashboard) | ✅ Built | Bedrock Agents activity (invocations, latency, token usage, model-call health) + Bedrock Guardrails behavior (intervention rate, interventions by policy category, latency/errors) |
| [ai-service-inventory-dashboard](cloudformation/ai-service-inventory-dashboard) | ✅ Built | Which regions actually have Bedrock, Bedrock Agents, Bedrock Guardrails, Rekognition, Comprehend, or Textract in active use — shadow AI adoption tracking via a scheduled multi-region CloudWatch scan |
| [network-exposure-dashboard](cloudformation/network-exposure-dashboard) | ✅ Built | Internet-open security groups, public EC2/RDS/load balancers, exposed S3 buckets by region, plus optional VPC Flow Log rejected-connection trends and port-scan detection |
| [nhi-governance-dashboard](cloudformation/nhi-governance-dashboard) | ✅ Built | Non-human identity risk: stale/unrotated access keys, users without MFA, inactive IAM users, stale IAM roles, external-trust roles, workload identity federation footprint, Secrets Manager rotation status |
| [eks-security-dashboard](cloudformation/eks-security-dashboard) | ✅ Built | EKS cluster/nodegroup Kubernetes version drift, stale node AMIs, nodegroup health issues, public-only API endpoints, GuardDuty EKS Protection findings, Inspector container image vulnerabilities |

All five dashboards from the original roadmap are built, plus a sixth
(nhi-governance) for non-human identity and a seventh (eks-security) for
Kubernetes/container security — both added because they're where a lot of
current enterprise cloud security attention is going. Ideas for further
dashboards: CloudFront/API Gateway exposure, EFS/FSx public mounts,
SageMaker endpoint cost and utilization, or cross-account rollups of any
dashboard here via StackSets — see each dashboard's own README for its
specific "Extending" notes.

## How each dashboard is wired

Pattern used across all dashboards in this repo:

1. **EventBridge rule(s)** capture relevant events (Security Hub findings, GuardDuty
   findings, Bedrock invocation logs, etc.)
2. Events land in a dedicated **CloudWatch Logs group**
3. **Metric filters** promote key fields (severity, finding type) into CloudWatch
   metrics for number/graph widgets
4. A **CloudWatch Dashboard** combines Logs Insights query widgets and metric
   widgets into one view

This means every dashboard here is really three building blocks
(EventBridge → Logs → Dashboard) that you can extend or recombine for your own
custom dashboards.

## Org-wide, multi-account deployment

By default every dashboard here is a single-account deployment
(`template.yaml` / `main.tf`). For running across an entire AWS
Organization from one central monitoring account, see
[`org-observability/`](org-observability/README.md) — it adds a CloudWatch
Observability Access Manager (OAM) sink/link setup plus a `collector` +
`org-dashboard` split for each dashboard, deployed via CloudFormation
StackSets. Two dashboards (`nhi-governance-dashboard`,
`agentic-ai-guardrails-dashboard`) have full org-wide versions today; the
rest have their collector half split out and ready, with the org-dashboard
recipe documented for finishing them.

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

## License

MIT — see [LICENSE](LICENSE)
