# Terraform configuration for EKS cluster and application deployment
terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.0"
        }
        kubernetes = {
            source  = "hashicorp/kubernetes"
            version = "~> 2.0"
        }
        helm = {
            source  = "hashicorp/helm"
            version = "~> 2.0"
        }
    }
    backend "s3" {
        bucket         = "ecommerce-terraform-state-sr-324037274946"
        key            = "terraform.tfstate"
        region         = "eu-west-2"
        dynamodb_table = "ecommerce-terraform-locks-sr"
    }
}

# AWS provider configuration
provider "aws" {
    region = var.region
}

# Kubernetes provider for EKS
provider "kubernetes" {
    host                   = aws_eks_cluster.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
    exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name]
        command     = "aws"
    }
}

# Helm provider for deploying AWS Load Balancer Controller
provider "helm" {
    kubernetes {
        host                   = aws_eks_cluster.eks_cluster.endpoint
        cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
        exec {
            api_version = "client.authentication.k8s.io/v1beta1"
            args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name]
            command     = "aws"
        }
    }
}

# VPC and networking
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "eks-vpc"
    }
}

resource "aws_subnet" "public" {
    count                   = 2
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.${count.index}.0/24"
    availability_zone       = element(data.aws_availability_zones.available.names, count.index)
    map_public_ip_on_launch = true
    tags = {
        Name = "eks-public-${count.index}"
        "kubernetes.io/role/elb" = "1"
    }
}

resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.main.id
    tags = {
        Name = "eks-igw"
    }
}

resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }
    tags = {
        Name = "eks-public-rt"
    }
}

resource "aws_route_table_association" "public" {
    count          = 2
    subnet_id      = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

# EKS cluster
resource "aws_eks_cluster" "eks_cluster" {
    name     = var.cluster_name
    role_arn = aws_iam_role.eks_cluster.arn
    vpc_config {
        subnet_ids = aws_subnet.public[*].id
    }
    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy
    ]
}

resource "aws_eks_node_group" "node_group" {
    cluster_name    = aws_eks_cluster.eks_cluster.name
    node_group_name = "eks-nodes"
    node_role_arn   = aws_iam_role.eks_nodes.arn
    subnet_ids      = aws_subnet.public[*].id
    scaling_config {
        desired_size = 2
        max_size     = 3
        min_size     = 1
    }
    depends_on = [
        aws_iam_role_policy_attachment.eks_worker_node_policy,
        aws_iam_role_policy_attachment.eks_cni_policy,
        aws_iam_role_policy_attachment.ecr_read_only
    ]
}

# IAM roles for EKS
resource "aws_iam_role" "eks_cluster" {
    name = "eks-cluster-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "eks.amazonaws.com"
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role" "eks_nodes" {
    name = "eks-nodes-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    role       = aws_iam_role.eks_nodes.name
}

# Security groups
resource "aws_security_group" "eks_nodes_sg" {
    name        = "eks-nodes-sg"
    vpc_id      = aws_vpc.main.id
    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups = [aws_security_group.alb_sg.id]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        Name = "eks-nodes-sg"
    }
}

resource "aws_security_group" "alb_sg" {
    name        = "eks-alb-sg"
    vpc_id      = aws_vpc.main.id
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        Name = "eks-alb-sg"
    }
}

# Kubernetes deployment
resource "kubernetes_deployment" "app" {
    metadata {
        name      = "eks-app-deployment"
        namespace = "default"
    }
    spec {
        replicas = 2
        selector {
            match_labels = {
                app = "eks-app"
            }
        }
        template {
            metadata {
                labels = {
                    app = "eks-app"
                }
            }
            spec {
                container {
                    image = var.ecr_image_uri
                    name  = "eks-app"
                    port {
                        container_port = 80
                    }
                }
            }
        }
    }
    depends_on = [
        aws_eks_node_group.node_group
    ]
}

# Kubernetes service with LoadBalancer
resource "kubernetes_service" "app_service" {
    metadata {
        name      = "eks-app-service"
        namespace = "default"
    }
    spec {
        selector = {
            app = "eks-app"
        }
        port {
            port        = 80
            target_port = 80
        }
        type = var.service_type
    }
    depends_on = [
        kubernetes_deployment.app
    ]
}

# AWS Load Balancer Controller
resource "aws_iam_policy" "load_balancer_controller" {
    name        = "AWSLoadBalancerControllerIAMPolicy"
    description = "Policy for AWS Load Balancer Controller"
    policy      = file("${path.module}/iam-policy.json")
}

resource "aws_iam_role" "load_balancer_controller" {
    name = "AWSLoadBalancerControllerRole"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Principal = {
                    Federated = "arn:aws:iam::${var.aws_account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/${replace(aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer, "https://", "")}"
                }
                Action = "sts:AssumeRoleWithWebIdentity"
                Condition = {
                    StringEquals = {
                        "oidc.eks.${var.region}.amazonaws.com/id/${replace(aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
                    }
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
    role       = aws_iam_role.load_balancer_controller.name
    policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "kubernetes_service_account" "load_balancer_controller" {
    metadata {
        name      = "aws-load-balancer-controller"
        namespace = "kube-system"
        annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.load_balancer_controller.arn
        }
    }
}

resource "helm_release" "load_balancer_controller" {
    name       = "aws-load-balancer-controller"
    repository = "https://aws.github.io/eks-charts"
    chart      = "aws-load-balancer-controller"
    namespace  = "kube-system"
    timeout    = 600  # Increased timeout to 10 minutes
    wait       = true
    set {
        name  = "clusterName"
        value = var.cluster_name
    }
    set {
        name  = "serviceAccount.create"
        value = "false"
    }
    set {
        name  = "serviceAccount.name"
        value = "aws-load-balancer-controller"
    }
    set {
        name  = "region"
        value = var.region
    }
    set {
        name  = "vpcId"
        value = aws_vpc.main.id
    }
    depends_on = [
        kubernetes_service_account.load_balancer_controller,
        aws_eks_node_group.node_group
    ]
}

# Data source for availability zones
data "aws_availability_zones" "available" {}
