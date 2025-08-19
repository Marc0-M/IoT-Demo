
# =========================
# Providers
# =========================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}


# =========================
# Resources
# =========================
data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(var.tags, {
    Name = var.name
  })
}

# Internet Gateway for public egress
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# Build subnet plans
locals {
  azs                   = var.azs
  public_subnet_count   = coalesce(var.num_public_subnets, length(local.azs))
  private_subnet_count  = var.create_private_subnets ? coalesce(var.num_private_subnets, length(local.azs)) : 0

  public_plan = {
    for idx in range(local.public_subnet_count) : tostring(idx) => {
      az   = local.azs[idx]
      cidr = var.public_subnet_cidrs == null ? cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, var.public_subnet_offset + idx) : var.public_subnet_cidrs[idx]
    }
  }

  private_plan = var.create_private_subnets ? {
    for idx in range(local.private_subnet_count) : tostring(idx) => {
      az   = local.azs[idx]
      cidr = var.private_subnet_cidrs == null ? cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, var.private_subnet_offset + idx) : var.private_subnet_cidrs[idx]
    }
  } : {}
}

# Public subnets
resource "aws_subnet" "public" {
  for_each                = local.public_plan
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags = merge(var.tags, {
    Name = "${var.name}-public-${each.value.az}-${each.key}",
    "kubernetes.io/role/elb" = "1"
  })
}

# Public route tables + routes + associations
resource "aws_route_table" "public" {
  for_each = aws_subnet.public
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name}-public-rt-${each.value.availability_zone}-${each.key}" })
}

resource "aws_route" "public_inet" {
  for_each               = aws_route_table.public
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public[each.key].id
}

# Private subnets (optional)
resource "aws_subnet" "private" {
  for_each                = local.private_plan
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags = merge(var.tags, {
    Name = "${var.name}-private-${each.value.az}-${each.key}",
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name}-private-rt-${each.value.availability_zone}-${each.key}" })
}

# NAT gateways (optional)
locals {
  nat_keys = var.create_private_subnets && var.create_nat_gateways ? (var.nat_per_az ? keys(local.private_plan) : ["0"]) : []
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_keys)
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-nat-eip-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.nat_keys)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[var.nat_per_az ? each.key : "0"].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
  depends_on    = [aws_internet_gateway.this]
}

# Private subnet default routes to NAT (when created)
resource "aws_route" "private_default" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.create_nat_gateways ? aws_nat_gateway.this[var.nat_per_az ? each.key : "0"].id : null
  lifecycle {
    precondition {
      condition     = var.create_private_subnets ? (var.create_nat_gateways ? true : false) : true
      error_message = "Private subnets require NAT or alternative egress; set create_nat_gateways=true or manage routes externally."
    }
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# Gateway Endpoints (S3/DynamoDB) — private route tables by default
locals {
  _private_rt_ids = values(aws_route_table.private)[*].id
  _public_rt_ids  = values(aws_route_table.public)[*].id
  _endpoint_rt_ids = var.endpoint_in_public_route_tables ? concat(local._private_rt_ids, local._public_rt_ids) : local._private_rt_ids
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.create_gateway_endpoints && var.create_s3_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.id}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local._endpoint_rt_ids
  tags              = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count             = var.create_gateway_endpoints && var.create_dynamodb_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.id}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local._endpoint_rt_ids
  tags              = merge(var.tags, { Name = "${var.name}-dynamodb-endpoint" })
}


# =========================
# Variables
# =========================
variable "name" {
  description = "Base name for resources (tags, names)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g., 10.0.0.0/16)."
  type        = string
}

variable "azs" {
  description = "List of availability zones to spread subnets across (e.g., [\"us-east-1a\", \"us-east-1b\"])."
  type        = list(string)
}

variable "num_public_subnets" {
  description = "How many public subnets to create (defaults to length(azs))."
  type        = number
  default     = null
}

variable "num_private_subnets" {
  description = "How many private subnets to create if enabled (defaults to length(azs))."
  type        = number
  default     = null
}

variable "public_subnet_cidrs" {
  description = "Optional explicit CIDR blocks for public subnets (must match num_public_subnets)."
  type        = list(string)
  default     = null
}

variable "private_subnet_cidrs" {
  description = "Optional explicit CIDR blocks for private subnets (must match num_private_subnets)."
  type        = list(string)
  default     = null
}

variable "public_subnet_newbits" {
  description = "Newbits used with cidrsubnet() when deriving public subnet CIDRs."
  type        = number
  default     = 8
}

variable "public_subnet_offset" {
  description = "Offset used with cidrsubnet() when deriving public subnet CIDRs."
  type        = number
  default     = 0
}

variable "private_subnet_newbits" {
  description = "Newbits used with cidrsubnet() when deriving private subnet CIDRs."
  type        = number
  default     = 8
}

variable "private_subnet_offset" {
  description = "Offset used with cidrsubnet() when deriving private subnet CIDRs."
  type        = number
  default     = 100
}

variable "create_private_subnets" {
  description = "Whether to create private subnets."
  type        = bool
  default     = true
}

variable "create_nat_gateways" {
  description = "Whether to create NAT gateways (only if private subnets exist)."
  type        = bool
  default     = true
}

variable "nat_per_az" {
  description = "If true, create one NAT gateway per AZ; otherwise create a single NAT."
  type        = bool
  default     = true
}

variable "create_gateway_endpoints" {
  description = "Whether to create gateway VPC endpoints."
  type        = bool
  default     = true
}

variable "create_s3_gateway_endpoint" {
  description = "Create an S3 gateway endpoint when gateway endpoints are enabled."
  type        = bool
  default     = true
}

variable "create_dynamodb_gateway_endpoint" {
  description = "Create a DynamoDB gateway endpoint when gateway endpoints are enabled."
  type        = bool
  default     = true
}

variable "endpoint_in_public_route_tables" {
  description = "Also associate gateway endpoints with public route tables (normally private only)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply."
  type        = map(string)
  default     = {}
}

# Validations
locals {
  _npub = coalesce(var.num_public_subnets, length(var.azs))
  _npri = var.create_private_subnets ? coalesce(var.num_private_subnets, length(var.azs)) : 0
}



# =========================
# Outputs
# =========================
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "IDs of private subnets (empty if disabled)"
  value       = [for s in aws_subnet.private : s.id]
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "IDs of NAT gateways (empty if disabled)"
  value       = [for n in aws_nat_gateway.this : n.id]
}

output "public_route_table_ids" {
  description = "IDs of public route tables"
  value       = [for rt in aws_route_table.public : rt.id]
}

output "private_route_table_ids" {
  description = "IDs of private route tables (empty if disabled)"
  value       = [for rt in aws_route_table.private : rt.id]
}

output "s3_gateway_endpoint_id" {
  description = "ID of S3 gateway endpoint (null if not created)"
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "dynamodb_gateway_endpoint_id" {
  description = "ID of DynamoDB gateway endpoint (null if not created)"
  value       = try(aws_vpc_endpoint.dynamodb[0].id, null)
}
