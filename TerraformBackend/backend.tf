# Terraform configuration for provisioning S3 bucket and DynamoDB table for backend
terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.0"
        }
    }
    backend "local" {
        path = "terraform.tfstate"
    }
}

provider "aws" {
    region = var.region
}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
    bucket = var.bucket_name
    tags = {
        Name = "terraform-state"
    }
}

resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
    bucket = aws_s3_bucket.terraform_state.id
    versioning_configuration {
        status = "Enabled"
    }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_encryption" {
    bucket = aws_s3_bucket.terraform_state.id
    rule {
        apply_server_side_encryption_by_default {
            sse_algorithm = "AES256"
        }
    }
}

resource "aws_s3_bucket_public_access_block" "terraform_state_access" {
    bucket = aws_s3_bucket.terraform_state.id
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
    name         = var.dynamodb_table_name
    billing_mode = "PAY_PER_REQUEST"
    hash_key     = "LockID"
    attribute {
        name = "LockID"
        type = "S"
    }
    tags = {
        Name = "terraform-locks"
    }
}

# Outputs
output "s3_bucket_name" {
    description = "Name of the S3 bucket for Terraform state"
    value       = aws_s3_bucket.terraform_state.bucket
}

output "dynamodb_table_name" {
    description = "Name of the DynamoDB table for Terraform state locking"
    value       = aws_dynamodb_table.terraform_locks.name
}

variable "region" {
    description = "AWS region"
    type        = string
    default     = "eu-west-2"
}

variable "bucket_name" {
    description = "Name of the S3 bucket for Terraform state"
    type        = string
    default     = "ecommerce-terraform-state-sr-324037274946"
}

variable "dynamodb_table_name" {
    description = "Name of the DynamoDB table for state locking"
    type        = string
    default     = "ecommerce-terraform-locks-sr"
}
