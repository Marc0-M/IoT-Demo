data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  table_defs  = var.tables
  table_names = { for k, t in local.table_defs : k => coalesce(lookup(t, "name", null), format("%s-%s", var.name_prefix, k)) }

  table_arns = {
    for k, name in local.table_names :
    k => "arn:aws:dynamodb:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/${name}"
  }

  table_index_arns = {
    for k, name in local.table_names :
    k => "arn:aws:dynamodb:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/${name}/index/*"
  }
}

# =========================
# Resources
# =========================

resource "aws_dynamodb_table" "this" {
  for_each     = local.table_defs
  name         = local.table_names[each.key]
  hash_key     = each.value.hash_key
  range_key    = try(each.value.range_key, null)                               # optional
  billing_mode = lookup(each.value, "billing_mode", "PAY_PER_REQUEST")
  table_class  = lookup(each.value, "table_class", "STANDARD")

  # Only for PROVISIONED
  read_capacity  = (lookup(each.value, "billing_mode", "PAY_PER_REQUEST") == "PROVISIONED") ? lookup(each.value, "read_capacity", 5)  : null
  write_capacity = (lookup(each.value, "billing_mode", "PAY_PER_REQUEST") == "PROVISIONED") ? lookup(each.value, "write_capacity", 5) : null

  # Attributes
  dynamic "attribute" {
    for_each = each.value.attributes
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  # Global Secondary Indexes
  dynamic "global_secondary_index" {
    for_each = lookup(each.value, "gsi", [])
    content {
      name               = global_secondary_index.value.name
      hash_key           = global_secondary_index.value.hash_key
      range_key          = try(global_secondary_index.value.range_key, null)
      projection_type    = global_secondary_index.value.projection_type
      non_key_attributes = try(global_secondary_index.value.non_key_attributes, null)
      read_capacity      = (lookup(each.value, "billing_mode", "PAY_PER_REQUEST") == "PROVISIONED") ? try(global_secondary_index.value.read_capacity, 5)  : null
      write_capacity     = (lookup(each.value, "billing_mode", "PAY_PER_REQUEST") == "PROVISIONED") ? try(global_secondary_index.value.write_capacity, 5) : null
    }
  }

  # Local Secondary Indexes
  dynamic "local_secondary_index" {
    for_each = lookup(each.value, "lsi", [])
    content {
      name               = local_secondary_index.value.name
      range_key          = local_secondary_index.value.range_key
      projection_type    = local_secondary_index.value.projection_type
      non_key_attributes = try(local_secondary_index.value.non_key_attributes, null)
    }
  }

  # Streams
  stream_enabled   = lookup(each.value, "stream_enabled", false)
  stream_view_type = try(each.value.stream_view_type, null)

  # TTL
  dynamic "ttl" {
    for_each = lookup(each.value, "ttl_enabled", false) ? [1] : []
    content {
      enabled        = true
      attribute_name = lookup(each.value, "ttl_attribute_name", "ttl")
    }
  }

  # Point-in-time recovery (PITR)
  dynamic "point_in_time_recovery" {
    for_each = [1]
    content { enabled = lookup(each.value, "point_in_time_recovery", true) }
  }

  # Server-side encryption (SSE/KMS)
  dynamic "server_side_encryption" {
    for_each = [1]
    content {
      enabled     = lookup(each.value, "sse_enabled", true)
      kms_key_arn = try(each.value.kms_key_arn, null)
    }
  }

  tags = merge(var.tags, lookup(each.value, "tags", {}))
}

# --------- Policy JSON outputs ---------
locals {

  endpoint_principal_obj = {
    AWS = length(var.endpoint_allowed_principals) > 0 ? var.endpoint_allowed_principals : ["*"]
  }

  endpoint_policy_doc = {
    Version   = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = local.endpoint_principal_obj
        Action    = var.rw_actions
        Resource  = concat(values(local.table_arns), values(local.table_index_arns))
      }
    ]
  }

  # Read/Write policy for all tables (useful for a shared IRSA role).
  rw_policy_doc = {
    Version   = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = var.rw_actions
        Resource = concat(values(local.table_arns), values(local.table_index_arns))
      }
    ]
  }

  # Read-only policy for all tables.
  ro_policy_doc = {
    Version   = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = var.ro_actions
        Resource = concat(values(local.table_arns), values(local.table_index_arns))
      }
    ]
  }

  # Per-table least-privilege (RW) policy.
  policy_by_table = {
    for k, arn in local.table_arns :
    k => {
      Version   = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = var.rw_actions
          Resource = [arn, local.table_index_arns[k]]
        }
      ]
    }
  }
}


# =========================
# Variables
# =========================

variable "name_prefix" {
  description = "Prefix for table names when a table.name isn't provided."
  type        = string
}

variable "tables" {
  description = "Map of table configs keyed by logical name."
  type = map(object({
    name         = optional(string)
    hash_key     = string
    range_key    = optional(string)
    attributes   = list(object({ name = string, type = string })) # type: S|N|B
    billing_mode = optional(string, "PAY_PER_REQUEST")            # or PROVISIONED
    read_capacity  = optional(number)                             # for PROVISIONED
    write_capacity = optional(number)                             # for PROVISIONED
    table_class    = optional(string, "STANDARD")                 # or STANDARD_INFREQUENT_ACCESS

    gsi = optional(list(object({
      name              = string
      hash_key          = string
      range_key         = optional(string)
      projection_type   = string                                  # ALL|KEYS_ONLY|INCLUDE
      non_key_attributes = optional(list(string))
      read_capacity     = optional(number)                         # for PROVISIONED
      write_capacity    = optional(number)                         # for PROVISIONED
    })), [])

    lsi = optional(list(object({
      name              = string
      range_key         = string
      projection_type   = string
      non_key_attributes = optional(list(string))
    })), [])

    stream_enabled     = optional(bool, false)
    stream_view_type   = optional(string)                          # NEW_IMAGE|OLD_IMAGE|NEW_AND_OLD_IMAGES|KEYS_ONLY

    ttl_enabled        = optional(bool, false)
    ttl_attribute_name = optional(string)

    point_in_time_recovery = optional(bool, true)

    sse_enabled  = optional(bool, true)
    kms_key_arn  = optional(string)

    tags = optional(map(string), {})
  }))
  default = {}
}

# If empty, the endpoint policy will set Principal:"*".
variable "endpoint_allowed_principals" {
  type        = list(string)
  default     = []
  description = "Optional IAM principal ARNs for the Endpoint policy (use '*' if empty)."
}

# Handy action sets for generated policies
variable "rw_actions" {
  type = list(string)
  default = [
    "dynamodb:DescribeTable",
    "dynamodb:ListTables",
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:BatchGetItem",
    "dynamodb:BatchWriteItem"
  ]
}
variable "ro_actions" {
  type = list(string)
  default = [
    "dynamodb:DescribeTable",
    "dynamodb:ListTables",
    "dynamodb:GetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:BatchGetItem"
  ]
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags."
}



# =========================
# Outputs
# =========================

output "table_names" {
  description = "Map logical key => actual table name"
  value       = local.table_names
}

output "table_arns" {
  description = "Map logical key => table ARN"
  value       = local.table_arns
}

# Attach to your VPC module's DynamoDB Gateway endpoint (policy argument)
output "endpoint_policy_json" {
  description = "Endpoint policy JSON that allows access (via VPC endpoint) to created tables."
  value       = jsonencode(local.endpoint_policy_doc)
}

# Handy JSONs to attach to IRSA roles (aws_iam_policy documents)
output "rw_policy_json" {
  description = "Read/write policy JSON for all tables."
  value       = jsonencode(local.rw_policy_doc)
}

output "ro_policy_json" {
  description = "Read-only policy JSON for all tables."
  value       = jsonencode(local.ro_policy_doc)
}

output "policy_by_table_json" {
  description = "Map logical key => JSON policy with read/write access to just that table (+ indexes)."
  value       = { for k, doc in local.policy_by_table : k => jsonencode(doc) }
}
