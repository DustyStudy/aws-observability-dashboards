#!/usr/bin/env python3
"""
Fails if a dashboard's CloudFormation inline Lambda (`Code.ZipFile`) and its
Terraform-standalone counterpart (terraform/<dashboard>/lambda/*.py) have
drifted apart.

Both IaC formats intentionally ship the *same* collector logic, hand-kept
in sync rather than built from one shared source file, because the CFN
template embeds it inline as a `ZipFile` string (no packaging step) while
the Terraform version zips a real .py file via the archive provider. That
duplication is exactly what let the eks-security-dashboard's Terraform copy
drift to a misleadingly-named variable while the CFN copy stayed correct —
this script exists so that class of bug fails CI instead of shipping.

Comparison is whitespace-normalized and comment-blind (so re-wrapped
comments/docstrings between the two formats don't trip it), but is
otherwise line-for-line: every non-comment line of code in one file must
appear in the other.
"""
import difflib
import io
import sys
import tokenize
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

# cfn template -> terraform standalone lambda file
PAIRS = {
    "cloudformation/bedrock-usage-cost-dashboard/template.yaml":
        "terraform/bedrock-usage-cost-dashboard/lambda/bedrock_cost_collector.py",
    "cloudformation/network-exposure-dashboard/template.yaml":
        "terraform/network-exposure-dashboard/lambda/network_exposure_collector.py",
    "cloudformation/nhi-governance-dashboard/template.yaml":
        "terraform/nhi-governance-dashboard/lambda/nhi_governance_collector.py",
    "cloudformation/ai-service-inventory-dashboard/template.yaml":
        "terraform/ai-service-inventory-dashboard/lambda/ai_service_inventory_collector.py",
    "cloudformation/eks-security-dashboard/template.yaml":
        "terraform/eks-security-dashboard/lambda/eks_patch_drift_checker.py",
}


class _IgnoreUnknownTagsLoader(yaml.SafeLoader):
    """Loads CloudFormation YAML by treating !Ref/!Sub/etc as plain values."""


def _multi_constructor(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


_IgnoreUnknownTagsLoader.add_multi_constructor("!", _multi_constructor)


def _extract_cfn_lambda_code(template_path):
    with open(template_path) as fh:
        data = yaml.load(fh, Loader=_IgnoreUnknownTagsLoader)
    for resource in data.get("Resources", {}).values():
        if resource.get("Type") == "AWS::Lambda::Function":
            code = resource.get("Properties", {}).get("Code", {})
            if "ZipFile" in code:
                return code["ZipFile"]
    raise ValueError(f"No inline Lambda ZipFile found in {template_path}")


def _normalized_code_lines(source_text):
    """
    Return a canonical token sequence for the code, ignoring anything that
    can differ between the two IaC formats without the logic actually
    differing: comments, docstrings, and how statements are line-wrapped
    (CFN's inline ZipFile tends to stay on one line per statement; the
    Terraform copy is usually black-formatted and wraps the same statement
    across several lines).

    Using tokenize instead of a line-by-line diff means "black wrapped this
    one function call across three lines" doesn't look like drift, while an
    actually-renamed variable or changed literal still does.
    """
    tokens = []
    try:
        token_gen = tokenize.generate_tokens(io.StringIO(source_text).readline)
        for tok in token_gen:
            if tok.type in (
                tokenize.COMMENT,
                tokenize.NL,
                tokenize.NEWLINE,
                tokenize.INDENT,
                tokenize.DEDENT,
                tokenize.ENCODING,
                tokenize.ENDMARKER,
            ):
                continue
            if tok.type == tokenize.STRING and tok.string.lstrip().startswith(
                ('"""', "'''")
            ):
                # Triple-quoted strings in these files are always
                # docstrings/module documentation, never runtime values —
                # rewording them isn't drift.
                continue
            tokens.append((tok.type, tok.string))
    except tokenize.TokenizeError:
        # Fall back to raw text if something unusual defeats the tokenizer;
        # better to over-report a possible drift than silently skip a file.
        return [source_text]
    return tokens


def check_pair(cfn_rel, tf_rel):
    cfn_path = REPO_ROOT / cfn_rel
    tf_path = REPO_ROOT / tf_rel

    cfn_code = _extract_cfn_lambda_code(cfn_path)
    tf_code = tf_path.read_text()

    cfn_tokens = _normalized_code_lines(cfn_code)
    tf_tokens = _normalized_code_lines(tf_code)

    if cfn_tokens == tf_tokens:
        return True

    print(f"DRIFT: {cfn_rel} vs {tf_rel}")
    matcher = difflib.SequenceMatcher(a=cfn_tokens, b=tf_tokens)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        cfn_snippet = " ".join(t[1] for t in cfn_tokens[i1:i2])
        tf_snippet = " ".join(t[1] for t in tf_tokens[j1:j2])
        print(f"  CFN: ...{cfn_snippet}...")
        print(f"  TF:  ...{tf_snippet}...")
    return False


def main():
    all_ok = True
    for cfn_rel, tf_rel in PAIRS.items():
        ok = check_pair(cfn_rel, tf_rel)
        status = "OK" if ok else "DRIFTED"
        print(f"[{status}] {cfn_rel} <-> {tf_rel}")
        all_ok = all_ok and ok

    if not all_ok:
        print(
            "\nOne or more CloudFormation/Terraform Lambda pairs have "
            "drifted apart. Update whichever copy is behind so both "
            "implement identical logic, then re-run this script."
        )
        sys.exit(1)

    print("\nAll CloudFormation/Terraform Lambda pairs match.")


if __name__ == "__main__":
    main()
