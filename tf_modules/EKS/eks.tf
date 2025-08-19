

# --- Security Groups ---
resource "aws_security_group" "cluster_additional" {
  name        = "${var.cluster_name}-cluster-additional"
  description = "Additional SG for EKS control plane ENIs"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { "eks/role" = "cluster-additional" })
}

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "Node security group for inter-node and API access"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { "eks/role" = "node" })
}


# Nodes -> control plane
resource "aws_security_group_rule" "cluster_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.cluster_additional.id
  source_security_group_id = aws_security_group.node.id
}

# Control plane -> nodes
resource "aws_security_group_rule" "node_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.node.id 
  source_security_group_id = aws_security_group.cluster_additional.id
}


# Inter-node allow (same SG)
resource "aws_security_group_rule" "node_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  self              = true
}


# Node egress (allow outbound)
resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.node.id
}

# --- IAM role for the EKS control plane ---
resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# --- EKS Cluster ---
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn

  version = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster_additional.id, aws_security_group.node.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode = var.authentication_mode
  }


  enabled_cluster_log_types = var.cluster_log_types

  dynamic "encryption_config" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]
    content {
      provider { key_arn = encryption_config.value }
      resources = ["secrets"]
    }
  }

  tags = var.tags
}


# --- EKS Addons ---
resource "aws_eks_addon" "this" {
  for_each                    = { for a in var.addons : a.name => a }
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value.name
  addon_version               = lookup(each.value, "version", null)
  resolve_conflicts_on_create = lookup(each.value, "resolve_conflicts", "OVERWRITE")
  resolve_conflicts_on_update = lookup(each.value, "resolve_conflicts", "OVERWRITE")
  configuration_values        = lookup(each.value, "configuration_values", null)
  tags                        = var.tags
  depends_on                  = [aws_eks_cluster.this]
}

# --- IAM for Node Groups ---
resource "aws_iam_role" "node" {
  for_each           = var.node_groups
  name               = "${var.cluster_name}-${each.key}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  for_each   = var.node_groups
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  for_each   = var.node_groups
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  for_each   = var.node_groups
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Extra managed policies per node group
resource "aws_iam_role_policy_attachment" "node_extra" {
  for_each = {
    for pair in flatten([
      for ng_name, ng in var.node_groups : [
        for policy_arn in lookup(ng, "iam_role_additional_policies", []) : {
          ng_name    = ng_name
          policy_arn = policy_arn
        }
      ]
    ]) : "${pair.ng_name}||${pair.policy_arn}" => pair
  }

  role       = aws_iam_role.node[each.value.ng_name].name
  policy_arn = each.value.policy_arn
}



# --- Managed Node Groups ---
resource "aws_eks_node_group" "this" {
  for_each        = var.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node[each.key].arn

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  subnet_ids     = coalesce(each.value.subnet_ids, var.subnet_ids)
  instance_types = each.value.instance_types
  disk_size      = each.value.disk_size
  capacity_type  = lookup(each.value, "capacity_type", "ON_DEMAND")
  ami_type       = lookup(each.value, "ami_type", null)

  # Map-based labels (Terraform attribute)
  labels = lookup(each.value, "labels", {})

  # Taints blocks
  dynamic "taint" {
    for_each = lookup(each.value, "taints", [])
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # Only create remote_access when an SSH key is set; use the managed node SG as the allowed source
  dynamic "remote_access" {
    for_each = lookup(each.value, "remote_access", null) == null || lookup(each.value.remote_access, "ec2_ssh_key", null) == null ? [] : [1]
    content {
      ec2_ssh_key               = each.value.remote_access.ec2_ssh_key
      source_security_group_ids = [aws_security_group.node.id]
    }
  }

  update_config { max_unavailable = 1 }

  tags = merge(var.tags, {
    "eks/cluster"    = var.cluster_name
    "eks/node_group" = each.key
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
  ]
}

# --- EKS Access Entries (optional; unchanged) ---
resource "aws_eks_access_entry" "this" {
  for_each = { for i, e in var.access_entries : i => e }
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  type          = lookup(each.value, "type", "STANDARD")
}

resource "aws_eks_access_policy_association" "this" {
  for_each = { for idx, entry in var.access_entries : idx => entry }
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policies[0]
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.this]
}

# --- OIDC provider (for IRSA) ---
data "tls_certificate" "oidc_thumbprint" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count           = var.enable_irsa ? 1 : 0
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc_thumbprint[0].certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# --- IRSA roles (per service account) ---
resource "aws_iam_policy" "irsa_inline" {
  for_each    = var.enable_irsa ? var.irsa_roles : {}
  name        = "${var.cluster_name}-${each.key}-irsa"
  description = lookup(each.value, "description", "IRSA policy")
  policy      = each.value.policy_json
}

data "aws_iam_policy_document" "irsa_assume" {
  for_each = var.enable_irsa ? var.irsa_roles : {}
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = format("%s:sub", replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", ""))
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = format("%s:aud", replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", ""))
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each           = var.enable_irsa ? var.irsa_roles : {}
  name               = "${var.cluster_name}-${each.key}-sa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.key].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "irsa_attach" {
  for_each   = var.enable_irsa ? var.irsa_roles : {}
  role       = aws_iam_role.irsa[each.key].name
  policy_arn = aws_iam_policy.irsa_inline[each.key].arn
}


# =========================
# Variables
# =========================
variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster (e.g., 1.30). Set null to let AWS pick default."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "VPC ID to launch the cluster in"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the cluster and node groups"
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the EKS public API endpoint is enabled"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Whether the EKS private API endpoint is enabled"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = "Control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for secrets encryption"
  type        = string
  default     = null
}

variable "addons" {
  description = "List of EKS addons to install"
  type = list(object({
    name                  = string
    version               = optional(string)
    resolve_conflicts     = optional(string, "OVERWRITE")
    configuration_values  = optional(string) 
  }))
  default = []
}

variable "node_groups" {
  description = "Map of managed node groups"
  type = map(object({
    desired_size  = number
    min_size      = number
    max_size      = number
    instance_types = list(string)
    disk_size     = number
    capacity_type = optional(string, "ON_DEMAND")
    labels        = optional(map(string), {})
    taints        = optional(list(object({
      key    = string
      value  = string
      effect = string # NO_SCHEDULE | PREFER_NO_SCHEDULE | NO_EXECUTE
    })), [])
    subnet_ids    = optional(list(string))
    ami_type      = optional(string)
    remote_access = optional(object({
      ec2_ssh_key               = optional(string)
      source_security_group_ids = optional(list(string), []) # ignored; module supplies its own
    }), {
      ec2_ssh_key               = null
      source_security_group_ids = []
    })
    iam_role_additional_policies = optional(list(string), [])
  }))
  default = {}
}


variable "authentication_mode" {
  description = "Configuration block for the access config associated with the cluster"
  default     = "API_AND_CONFIG_MAP"
}


variable "access_entries" {
  description = "Optional access entries to grant cluster access without editing aws-auth"
  type = list(object({
    principal_arn = string
    type          = optional(string, "STANDARD")
    policies      = list(string)
  }))
  default = []
}

variable "enable_irsa" {
  description = "Create an IAM OIDC provider and IRSA roles"
  type        = bool
  default     = true
}

variable "irsa_roles" {
  description = "Map of IRSA roles to create (keyed by logical name)"
  type = map(object({
    namespace       = string
    service_account = string
    policy_json     = string
    description     = optional(string, "IRSA role")
  }))
  default = {}
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# =========================
# Outputs
# =========================
output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version reported by the cluster"
  value       = aws_eks_cluster.this.version
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN (null if IRSA disabled)"
  value       = try(aws_iam_openid_connect_provider.this[0].arn, null)
}

output "node_group_names" {
  description = "Names of created managed node groups"
  value       = keys(aws_eks_node_group.this)
}

output "cluster_additional_security_group_id" {
  description = "ID of the additional SG attached to EKS control plane ENIs"
  value       = aws_security_group.cluster_additional.id
}

output "node_security_group_id" {
  description = "ID of the managed node security group"
  value       = aws_security_group.node.id
}

output "irsa_role_arns" {
  description = "Map of IRSA role ARNs keyed by irsa_roles keys"
  value       = try({ for k, r in aws_iam_role.irsa : k => r.arn }, {})
}
