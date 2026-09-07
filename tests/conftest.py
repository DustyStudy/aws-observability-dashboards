"""
Makes each dashboard's standalone Lambda source importable by test module
name (e.g. `import network_exposure_collector`) without turning
terraform/*/lambda/ into Python packages — these files are deployed as
single-file Lambda handlers, not a package, so no __init__.py belongs there.
"""
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

LAMBDA_DIRS = [
    "terraform/bedrock-usage-cost-dashboard/lambda",
    "terraform/network-exposure-dashboard/lambda",
    "terraform/nhi-governance-dashboard/lambda",
    "terraform/ai-service-inventory-dashboard/lambda",
    "terraform/eks-security-dashboard/lambda",
]

for rel_dir in LAMBDA_DIRS:
    abs_dir = str(REPO_ROOT / rel_dir)
    if abs_dir not in sys.path:
        sys.path.insert(0, abs_dir)

# Every collector creates its boto3 clients inside its handler function, not
# at module import time, specifically so importing the module for tests
# never needs a resolvable AWS region (a real Lambda invocation always has
# one; a local/CI Python process doesn't). This is a backstop, not the
# fix: if a future collector accidentally creates a client at import time
# again, this keeps that a normal (loud) test failure inside a mocked test
# instead of an unrunnable "NoRegionError during collection" that takes the
# whole test session down before anything else can run.
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
