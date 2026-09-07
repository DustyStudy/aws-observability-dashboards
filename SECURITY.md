# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, please report it privately — **do not open a public GitHub issue**.

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) feature (Security tab → "Report a vulnerability" on this repo) with a description of the issue, steps to reproduce, and any relevant logs or templates. Please do not include real AWS account IDs, ARNs, or credentials in your report.

You can expect an initial response within 5 business days.

## Scope

This repository provides CloudWatch dashboard CloudFormation and Terraform templates for security posture, AI/ML usage, and agentic AI observability, designed to work at the AWS Organization level in both commercial and GovCloud. This includes per-account collector Lambdas deployed via StackSets to a dedicated monitoring account. Reports in scope include:

- Logic errors in collector Lambdas or IAM roles that could over-expose data or grant excessive cross-account access
- Supply-chain concerns (malicious or unpinned dependencies, GitHub Actions)
- Secrets or credentials accidentally committed to this repo

Out of scope: vulnerabilities in AWS services themselves (report those to AWS), or issues in downstream forks/deployments not present in this repo's source.

## Supported Versions

This repository does not publish tagged releases — templates are consumed directly
from the `main` branch, which is the only branch that receives security fixes.
Forks or copies pinned to an older commit should re-sync with `main` to pick up fixes.
