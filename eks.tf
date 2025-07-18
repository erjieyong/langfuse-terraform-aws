data "aws_eks_cluster_auth" "langfuse" {
  name = aws_eks_cluster.langfuse.name
}

resource "aws_eks_cluster" "langfuse" {
  name     = var.name
  role_arn = aws_iam_role.eks.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name = local.tag_name
    group = "lta-cc-sandbox-aidp-aid"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
    aws_cloudwatch_log_group.eks
  ]
}

# Enable IRSA
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer

  tags = {
    Name = local.tag_name
    group = "lta-cc-sandbox-aidp-aid"
  }
}

# Get EKS OIDC certificate
data "tls_certificate" "eks" {
  url = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer
}

# Fargate Profile Role
resource "aws_iam_role" "fargate" {
  name = "${var.name}-fargate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.tag_name} Fargate"
    group = "lta-cc-sandbox-aidp-aid"
  }
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate.name
}

# Fargate Profiles for all configured namespaces
resource "aws_eks_fargate_profile" "namespaces" {
  for_each = toset(var.fargate_profile_namespaces)

  cluster_name           = aws_eks_cluster.langfuse.name
  fargate_profile_name   = "${var.name}-${each.value}"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = module.vpc.private_subnets

  selector {
    namespace = each.value
  }

  tags = {
    Name = local.tag_name
    group = "lta-cc-sandbox-aidp-aid"
  }
}

# for the default security group
# Fetch the cluster’s computed SG ID
data "aws_eks_cluster" "langfuse" {
  name = aws_eks_cluster.langfuse.name
}

# 1 Allow HTTPS outbound to all IPv4
resource "aws_security_group_rule" "default_eks_egress_https_all_ipv4" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description       = "Allow HTTPS outbound to all IPv4"
}

# 2 Allow HTTP outbound to all IPv4
resource "aws_security_group_rule" "default_eks_egress_http_all_ipv4" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description       = "Allow HTTP outbound to all IPv4"
}

# 3 Allow all traffic to its own Cluster security group
resource "aws_security_group_rule" "default_eks_egress_self" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1" # All protocols
  source_security_group_id = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id # Allows traffic to itself
  security_group_id        = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description              = "Allow all outbound traffic to self (cluster SG)"
}

# 4 Allow all traffic to its own vpc
resource "aws_security_group_rule" "default_eks_egress_self_vpc" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  cidr_blocks              = [module.vpc.vpc_cidr_block]
  security_group_id        = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description              = "Allow all outbound traffic to self vpc"
}


resource "aws_security_group_rule" "default_eks_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [module.vpc.vpc_cidr_block]
  security_group_id = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description       = "Allow all traffic from VPC"
}

resource "aws_security_group_rule" "default_eks_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = data.aws_eks_cluster.langfuse.vpc_config[0].cluster_security_group_id
  description       = "Allow all traffic from same security group"
}


# for additional security group
resource "aws_security_group" "eks" {
  name        = "${var.name}-eks"
  description = "Security group for Langfuse EKS cluster"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.tag_name} EKS"
    group = "lta-cc-sandbox-aidp-aid"
  }
}

# Remove the existing overly permissive egress rule
# resource "aws_security_group_rule" "eks_egress" {
#   type              = "egress"
#   from_port         = 0
#   to_port           = 0
#   protocol          = "-1"
#   cidr_blocks       = ["0.0.0.0/0"]
#   security_group_id = aws_security_group.eks.id
# }

# 1 Allow HTTPS outbound to all IPv4
resource "aws_security_group_rule" "eks_egress_https_all_ipv4" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks.id
  description       = "Allow HTTPS outbound to all IPv4"
}

# 2 Allow HTTP outbound to all IPv4
resource "aws_security_group_rule" "eks_egress_http_all_ipv4" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks.id
  description       = "Allow HTTP outbound to all IPv4"
}

# 3 Allow all traffic to its own Cluster security group
resource "aws_security_group_rule" "eks_egress_self" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1" # All protocols
  source_security_group_id = aws_security_group.eks.id # Allows traffic to itself
  security_group_id        = aws_security_group.eks.id
  description              = "Allow all outbound traffic to self (cluster SG)"
}

# 4 Allow all traffic to its own vpc
resource "aws_security_group_rule" "eks_egress_self_vpc" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  cidr_blocks              = [module.vpc.vpc_cidr_block]
  security_group_id        = aws_security_group.eks.id
  description              = "Allow all outbound traffic to self vpc"
}


resource "aws_security_group_rule" "eks_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [module.vpc.vpc_cidr_block]
  security_group_id = aws_security_group.eks.id
  description       = "Allow all traffic from VPC"
}

resource "aws_security_group_rule" "eks_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.eks.id
  description       = "Allow all traffic from same security group"
}

resource "aws_iam_role" "eks" {
  name = "${var.name}-eks"

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

  tags = {
    Name = "${local.tag_name} EKS"
    group = "lta-cc-sandbox-aidp-aid"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 30
} 