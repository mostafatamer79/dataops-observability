#!/bin/bash
set -euo pipefail

# ============================================================
# DataOps - Build & Deploy Script
# 1. Runs Terraform to create AWS infrastructure
# 2. Automatically extracts Public IPs from running EC2 instances
# 3. Generates Ansible inventory.ini dynamically
# 4. Waits for SSH readiness
# 5. Runs Ansible playbook to configure all nodes
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
INVENTORY_FILE="$SCRIPT_DIR/inventory.ini"
SSH_KEY="$SCRIPT_DIR/dataops-key.pem"

echo -e "${GREEN}=== DataOps Infrastructure Build Script ===${NC}"

# --------------------------------------------------
# Prerequisites Check
# --------------------------------------------------
echo -e "${BLUE}[CHECK] Verifying prerequisites...${NC}"
for cmd in terraform aws ansible-playbook; do
  if ! command -v "$cmd" &> /dev/null; then
    echo -e "${RED}[FAIL] $cmd is not installed or not in PATH${NC}"
    exit 1
  fi
done
echo -e "${GREEN}[OK] All prerequisites found${NC}"

# Check SSH key
if [[ ! -f "$SSH_KEY" ]]; then
  echo -e "${YELLOW}[WARN] SSH key not found at $SSH_KEY${NC}"
  echo "       Make sure your Terraform creates it, or place it manually."
fi

# --------------------------------------------------
# 1. Terraform Apply
# --------------------------------------------------
echo -e "${GREEN}[1/5] Running Terraform Apply...${NC}"
cd "$TERRAFORM_DIR"
terraform init
terraform apply -auto-approve

# --------------------------------------------------
# 2. Extract Public IPs from AWS
# --------------------------------------------------
echo -e "${GREEN}[2/5] Waiting for EC2 instances to get Public IPs...${NC}"
MAX_RETRIES=30
RETRY_DELAY=10

MONITORING_IP=""
WORKER1_IP=""
WORKER2_IP=""

for ((i=1; i<=MAX_RETRIES; i++)); do
  MONITORING_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=monitoring-server" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].PublicIpAddress' --output text 2>/dev/null || true)

  WORKER1_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=worker-1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].PublicIpAddress' --output text 2>/dev/null || true)

  WORKER2_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=worker-2" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].PublicIpAddress' --output text 2>/dev/null || true)

  if [[ -n "$MONITORING_IP" && -n "$WORKER1_IP" && -n "$WORKER2_IP" ]]; then
    echo -e "${GREEN}[OK] All Public IPs acquired:${NC}"
    echo "       monitoring-server : $MONITORING_IP"
    echo "       worker-1          : $WORKER1_IP"
    echo "       worker-2          : $WORKER2_IP"
    break
  fi

  echo -e "${YELLOW}       Waiting... attempt $i/$MAX_RETRIES${NC}"
  sleep $RETRY_DELAY
done

if [[ -z "$MONITORING_IP" || -z "$WORKER1_IP" || -z "$WORKER2_IP" ]]; then
  echo -e "${RED}[FAIL] Could not retrieve all Public IPs from AWS${NC}"
  echo "       Check that your Terraform tags the instances with:"
  echo "         Name = monitoring-server, worker-1, worker-2"
  exit 1
fi

# --------------------------------------------------
# 3. Generate Ansible inventory.ini
# --------------------------------------------------
echo -e "${GREEN}[3/5] Generating Ansible inventory.ini...${NC}"
cat > "$INVENTORY_FILE" <<EOF
[monitoring]
monitoring-server ansible_host=${MONITORING_IP} ansible_user=ec2-user

[workers]
worker-1 ansible_host=${WORKER1_IP} ansible_user=ec2-user
worker-2 ansible_host=${WORKER2_IP} ansible_user=ec2-user

[all:vars]
ansible_ssh_private_key_file=./dataops-key.pem
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

echo -e "${GREEN}[OK] inventory.ini created at:${NC} $INVENTORY_FILE"

# --------------------------------------------------
# 4. Wait for SSH readiness
# --------------------------------------------------
echo -e "${GREEN}[4/5] Waiting for SSH on all hosts...${NC}"
for host in "$MONITORING_IP" "$WORKER1_IP" "$WORKER2_IP"; do
  echo -n "       Checking $host ... "
  until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" ec2-user@"$host" "echo OK" &>/dev/null; do
    echo -n "."
    sleep 5
  done
  echo -e "${GREEN}READY${NC}"
done

# --------------------------------------------------
# 5. Run Ansible Playbook
# --------------------------------------------------
echo -e "${GREEN}[5/5] Running Ansible Playbook...${NC}"
cd "$SCRIPT_DIR"
ansible-playbook -i inventory.ini playbook.yml

echo ""
echo -e "${GREEN}=== BUILD COMPLETE ===${NC}"
echo ""
echo "  Grafana UI      : http://${MONITORING_IP}:3000"
echo "  Prometheus UI   : http://${MONITORING_IP}:9090"
echo "  Node Exporter   : http://${MONITORING_IP}:9100/metrics"
echo "  Cribl Edge      : http://${MONITORING_IP}:9420"
echo ""
