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
| ai-bedrock-usage-dashboard | Planned | Bedrock invocations, tokens, cost, and throttling by model |
| ai-service-inventory-dashboard | Planned | Which accounts/regions have Bedrock, Rekognition, Comprehend, Textract enabled |
| agentic-ai-guardrails-dashboard | Planned | Bedrock Agents activity + Bedrock Guardrails blocked/flagged content |
| network-exposure-dashboard | Planned | Public-facing resources, open security groups, VPC Flow Log anomalies |

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
