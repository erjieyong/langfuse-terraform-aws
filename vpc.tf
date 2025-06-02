data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway     = true
  single_nat_gateway     = !var.use_single_nat_gateway
  one_nat_gateway_per_az = var.use_single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  # Add required tags for the AWS Load Balancer Controller
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }

  tags = {
    Name = local.tag_name
    group = "lta-cc-sandbox-aidp-aid"
  }
}

# VPC Endpoints for AWS services
resource "aws_vpc_endpoint" "sts" {
  vpc_id             = module.vpc.vpc_id
  service_name       = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  private_dns_enabled = true

  tags = {
    Name = "${local.tag_name} STS VPC Endpoint"
    group = "lta-cc-sandbox-aidp-aid"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${local.tag_name} S3 VPC Endpoint"
    group = "lta-cc-sandbox-aidp-aid"
  }
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  tags = {
    Name = "${local.tag_name} VPC Endpoints"
    group = "lta-cc-sandbox-aidp-aid"
  }
} 

# search for the default load balancer security group that was created
data "aws_security_group" "lbc_backend_sg" {
  filter {
    name   = "tag:elbv2.k8s.aws/cluster"
    values = [var.name] # Assuming var.name is your EKS cluster name
  }
  filter {
    name   = "tag:elbv2.k8s.aws/resource"
    values = ["backend-sg"]
  }
}

# edit the egress rule for the security group
resource "aws_security_group_rule" "lbc_backend_sg_outbound_vpc" {
  # count = data.aws_security_group.lbc_backend_sg.id != "" ? 1 : 0 # Ensure SG is found

  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [module.vpc.vpc_cidr_block]
  security_group_id = data.aws_security_group.lbc_backend_sg.id
  description       = "Allow all outbound TCP to VPC (Terraform managed - LBC SG)"
}
