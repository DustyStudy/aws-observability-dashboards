"""
Makes each dashboard's standalone Lambda source importable by test module
name (e.g. `import network_exposure_collector`) without turning
terraform/*/lambda/ into Python packages — these files are deployed as
single-file Lambda handlers, not a package, so no __init__.py belongs there.
"""
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
