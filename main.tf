provider "aws" {
  version = "~> 6.0"
  region  = "us-east-2"
}

# -------------------------
# VPC
# -------------------------
module "vpc" {
  source = "./tf_modules/vpc"

  name     = "demo-vpc"
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-2a", "us-east-2b", "us-east-2c"]


  create_private_subnets = true
  create_nat_gateways    = true
  nat_per_az             = true

  create_gateway_endpoints         = true
  create_s3_gateway_endpoint       = false
  create_dynamodb_gateway_endpoint = true

  endpoint_in_public_route_tables = false
  public_subnet_cidrs  = null   
  private_subnet_cidrs = null   
  public_subnet_newbits  = 8
  public_subnet_offset   = 10
  private_subnet_newbits = 8
  private_subnet_offset  = 20

  tags = {
    Project = "Demo"
    Env     = "Dev"
    "kubernetes.io/cluster/demo-eks" = "shared"
  }
}

# -------------------------
# EKS
# -------------------------
module "eks" {
  source = "./tf_modules/eks"

  cluster_name       = "demo-eks"
  kubernetes_version = "1.32"

  # Wire to VPC module outputs (still no var.*)
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = ["0.0.0.0/0"] # as requested

  addons = [
    { name = "vpc-cni" },
    { name = "kube-proxy" },
    { name = "coredns" }
  ]

  node_groups = {
    general = {
      desired_size   = 2
      min_size       = 2
      max_size       = 3
      instance_types = ["t3.medium"]
      disk_size      = 50
      labels         = { role = "general" }
      taints         = []
      capacity_type  = "ON_DEMAND"
      iam_role_additional_policies = [
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ]
    }
    spot = {
      desired_size   = 2
      min_size       = 0
      max_size       = 10
      instance_types = ["t3.medium", "t3a.medium"]
      disk_size      = 30
      capacity_type  = "SPOT"
      labels         = { lifecycle = "spot" }
      taints         = []
    }
  }

  enable_irsa = true
  irsa_roles = {
    iot_receiver = {
      namespace       = "apps"
      service_account = "iot-receiver"
      policy_json     = module.ddb.policy_by_table_json["iot"]
    }
  }

  access_entries = [{
    principal_arn = "arn:aws:iam::996939000921:user/marco_magdy",
    policies      = ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"]
  }]

  tags = {
    Project = "Demo"
    Env     = "Dev"
  }
}


# -------------------------
# DynamoDB
# -------------------------

module "ddb" {
  source      = "./tf_modules/dynamodb"
  name_prefix = "iot"  

  tables = {
    iot = {
      name         = "iot"             
      billing_mode = "PAY_PER_REQUEST" 
      hash_key     = "deviceId"
      range_key    = "Time"
      
      attributes = [
        { name = "deviceId", type = "S" },
        { name = "temperature", type = "N" },
        { name = "Time", type = "S" }
      ]

      lsi = [
        {
          name            = "byTemp"
          range_key       = "temperature"
          projection_type = "ALL"
        }
      ]


      point_in_time_recovery = true
      sse_enabled            = true
      ttl_enabled            = true
      ttl_attribute_name     = "ttl"
      tags                   = { Domain = "iot" }
    }
  }


  endpoint_allowed_principals = [module.eks.irsa_role_arns]

  tags = {
    Project = "Demo"
    Env     = "Dev"
  }
}