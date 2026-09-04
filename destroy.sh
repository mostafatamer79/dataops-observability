#!/bin/bash
set -euo pipefail

# ============================================================
# DataOps - Destroy & Cleanup Script
# 1. Destroys all Terraform-managed AWS resources
# 2. Cleans up local state, cache, and temporary files
# 3. Resets inventory.ini to placeholder template
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"

echo -e "${GREEN}=== DataOps Infrastructure Destroy Script ===${NC}"

# Check Terraform
if ! command -v terraform &> /dev/null; then
  echo -e "${RED}[FAIL] terraform is not installed${NC}"
  exit 1
fi

# --------------------------------------------------
# 1. Terraform Destroy
# --------------------------------------------------
echo -e "${GREEN}[1/3] Destroying Terraform resources...${NC}"
cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

# --------------------------------------------------
# 2. Local Cleanup
# --------------------------------------------------
echo -e "${GREEN}[2/3] Cleaning up local files...${NC}"
cd "$SCRIPT_DIR"

# Terraform cache & state
rm -rf terraform/.terraform
rm -f terraform/.terraform.lock.hcl
rm -f terraform/terraform.tfstate
rm -f terraform/terraform.tfstate.backup
rm -f terraform/terraform.tfplan

# Ansible retry files
rm -f playbook.retry

# Temporary downloads
rm -f /tmp/node_exporter*.tar.gz
rm -f /tmp/prometheus*.tar.gz

echo -e "${GREEN}[OK] Local files cleaned${NC}"

# --------------------------------------------------
# 3. Reset inventory.ini
# --------------------------------------------------
echo -e "${GREEN}[3/3] Resetting inventory.ini to template...${NC}"
cat > inventory.ini <<'EOF'
[monitoring]
monitoring-server ansible_host=REPLACE_WITH_MONITORING_IP ansible_user=ec2-user

[workers]
worker-1 ansible_host=REPLACE_WITH_WORKER1_IP ansible_user=ec2-user
worker-2 ansible_host=REPLACE_WITH_WORKER2_IP ansible_user=ec2-user

[all:vars]
ansible_ssh_private_key_file=./dataops-key.pem
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

echo -e "${GREEN}[OK] inventory.ini reset${NC}"

# Optional: remove SSH keys (uncomment if you want to delete them)
# rm -f dataops-key.pem
# rm -f dataops-key.pem.pub

echo ""
echo -e "${GREEN}=== DESTROY COMPLETE ===${NC}"
echo "       All AWS resources have been destroyed."
echo "       Local state and cache have been cleaned."
