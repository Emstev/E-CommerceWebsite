variable "region" {
    description = "AWS region"
    type        = string
    default     = "us-west-2"
}

variable "cluster_name" {
    description = "EKS cluster name"
    type        = string
}

variable "ecr_image_uri" {
    description = "ECR image URI for the application"
    type        = string
}

variable "service_type" {
    description = "Kubernetes service type"
    type        = string
    default     = "LoadBalancer"
}

variable "aws_account_id" {
    description = "AWS Account ID"
    type        = string
}
