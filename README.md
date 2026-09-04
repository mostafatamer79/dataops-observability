# DataOps Observability & Data Pipeline

Terraform provisions an AWS VPC, three EC2 instances, S3 storage, IAM roles, and network controls. Ansible configures Prometheus, Grafana, node_exporter, and Cribl Edge.

## Prerequisites

- Terraform >= 1.5
- AWS CLI authenticated to the target account
- Ansible
- A GitHub release of the project does **not** contain infrastructure state, SSH keys, or secrets.

## Configuration

Set the following variables before running the playbook:

```bash
export CRIBL_TOKEN='your-cribl-token'
export GRAFANA_ADMIN_PASSWORD='use-a-strong-unique-password'
```

For Terraform, always restrict management access to your public IP:

```bash
terraform apply -var="my_ip=203.0.113.10"
```

## Deploy

The current Terraform configuration is at the repository root:

```bash
terraform init
terraform apply
ansible-playbook -i inventory.ini playbook.yml
```

Do not commit `*.tfstate`, `*.pem`, `*.tfvars`, `inventory.ini`, or vault files. Configure a remote encrypted Terraform backend before using this for shared or production infrastructure.
