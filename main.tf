# ============================================================
# DataOps Observability & Data Pipeline - Terraform
# Full Infrastructure as Code
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# Variables
# ============================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for tagging"
  type        = string
  default     = "DataOps"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone"
  type        = string
  default     = "us-east-1a"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
  default     = "dataops-key"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "Your public IP address for SSH/Grafana access (e.g., 203.0.113.45)"
  type        = string
  default     = ""
}

# ============================================================
# Data Sources
# ============================================================

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  admin_cidr = var.my_ip != "" ? "${var.my_ip}/32" : "0.0.0.0/0"
}

# ============================================================
# SSH Key Pair (Auto-generated)
# ============================================================

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Name    = var.key_name
    Project = var.project_name
  }
}

# Save private key locally
resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/${var.key_name}.pem"
  file_permission = "0400"
}


# ============================================================
# VPC & Networking
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "dataops-vpc"
    Project = var.project_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "dataops-igw"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name    = "dataops-public-subnet"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "dataops-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ============================================================
# Security Group
# ============================================================

resource "aws_security_group" "main" {
  name        = "dataops-sg"
  description = "Security group for DataOps observability project"
  vpc_id      = aws_vpc.main.id

  # SSH - admin only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  # Grafana - admin only
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  # Prometheus - internal VPC
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # node_exporter - internal VPC
  ingress {
    description = "node_exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Cribl Edge - internal VPC
  ingress {
    description = "Cribl Edge"
    from_port   = 9420
    to_port     = 9420
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # All outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "dataops-sg"
    Project = var.project_name
  }
}

# ============================================================
# IAM Roles
# ============================================================

resource "aws_iam_role" "ec2" {
  name = "EC2-DataOps-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

# S3 Policy for Cribl Edge
resource "aws_iam_policy" "s3" {
  name        = "DataOps-S3-Policy"
  description = "S3 access for DataOps project"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "S3Access"
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.main.arn,
        "${aws_s3_bucket.main.arn}/*"
      ]
    }]
  })
}

# Kinesis Policy (for when account is upgraded)
resource "aws_iam_policy" "kinesis" {
  name        = "DataOps-Kinesis-Policy"
  description = "Kinesis access for DataOps project"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "KinesisPutRecords"
      Effect = "Allow"
      Action = [
        "kinesis:PutRecord",
        "kinesis:PutRecords",
        "kinesis:DescribeStream"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.s3.arn
}

resource "aws_iam_role_policy_attachment" "kinesis" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.kinesis.arn
}

resource "aws_iam_instance_profile" "main" {
  name = "EC2-DataOps-Profile"
  role = aws_iam_role.ec2.name
}

# ============================================================
# S3 Bucket
# ============================================================

resource "aws_s3_bucket" "main" {
  bucket = "dataops-project-bucket-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "dataops-project-bucket"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# Kinesis (Commented out - requires account upgrade)
# ============================================================

/*
resource "aws_kinesis_stream" "main" {
  name        = "dataops-kensis-stream"
  shard_count = 1

  tags = {
    Name    = "dataops-kensis-stream"
    Project = var.project_name
  }
}

resource "aws_iam_role" "firehose" {
  name = "Firehose-DataOps-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "firehose_s3" {
  name = "Firehose-S3-Policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "S3Access"
      Effect = "Allow"
      Action = [
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:PutObject",
        "s3:PutObjectAcl"
      ]
      Resource = [
        aws_s3_bucket.main.arn,
        "${aws_s3_bucket.main.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "firehose" {
  role       = aws_iam_role.firehose.name
  policy_arn = aws_iam_policy.firehose_s3.arn
}

resource "aws_kinesis_firehose_delivery_stream" "main" {
  name        = "firehose-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.main.arn
    prefix     = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size     = 5
    buffering_interval = 60
    compression_format = "UNCOMPRESSED"
  }

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.main.arn
    role_arn           = aws_iam_role.firehose.arn
  }
}
*/

# ============================================================
# EC2 Instances
# ============================================================

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.public.id
  private_ip             = "10.0.1.10"
  iam_instance_profile   = aws_iam_instance_profile.main.name

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name    = "monitoring-server"
    Project = var.project_name
  }
}

resource "aws_instance" "worker_1" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.public.id
  private_ip             = "10.0.1.11"
  iam_instance_profile   = aws_iam_instance_profile.main.name

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name    = "worker-1"
    Project = var.project_name
  }
}

resource "aws_instance" "worker_2" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.public.id
  private_ip             = "10.0.1.12"
  iam_instance_profile   = aws_iam_instance_profile.main.name

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name    = "worker-2"
    Project = var.project_name
  }
}

# ============================================================
# Outputs
# ============================================================

output "monitoring_server_public_ip" {
  description = "Public IP of monitoring server"
  value       = aws_instance.monitoring.public_ip
}

output "monitoring_server_private_ip" {
  description = "Private IP of monitoring server"
  value       = aws_instance.monitoring.private_ip
}

output "worker_1_public_ip" {
  description = "Public IP of worker 1"
  value       = aws_instance.worker_1.public_ip
}

output "worker_1_private_ip" {
  description = "Private IP of worker 1"
  value       = aws_instance.worker_1.private_ip
}

output "worker_2_public_ip" {
  description = "Public IP of worker 2"
  value       = aws_instance.worker_2.public_ip
}

output "worker_2_private_ip" {
  description = "Private IP of worker 2"
  value       = aws_instance.worker_2.private_ip
}

output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.main.bucket
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus web UI URL"
  value       = "http://${aws_instance.monitoring.public_ip}:9090"
}

output "ssh_command_monitoring" {
  description = "SSH command for monitoring server"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.monitoring.public_ip}"
}

output "ssh_command_worker_1" {
  description = "SSH command for worker 1"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.worker_1.public_ip}"
}

output "ssh_command_worker_2" {
  description = "SSH command for worker 2"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.worker_2.public_ip}"
}

output "ssh_private_key_path" {
  description = "Path to generated SSH private key"
  value       = local_file.private_key.filename
}

output "ssh_private_key_content" {
  description = "SSH private key content (sensitive)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
