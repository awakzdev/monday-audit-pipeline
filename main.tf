locals {
  secret_name = "${var.env}/${var.lambda_config.name}/secret"
}

# ──────────────────────────────────────────────
# Lambda
# ──────────────────────────────────────────────
module "lambda" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-lambda"

  name                    = var.lambda_config.name
  timeout                 = var.lambda_config.timeout
  memory_size             = var.lambda_config.memory_size
  ephemeral_storage_size  = var.lambda_config.ephemeral_storage_size
  ignore_source_code_hash = var.lambda_config.ignore_source_code_hash

  package_type = var.lambda_config.package_type
  filename     = var.lambda_config.filename
  handler      = var.lambda_config.handler
  runtime      = var.lambda_config.runtime

  environment_variables = merge(
    {
      SECRET_NAME = local.secret_name
      SECRET_ARN  = module.secrets_manager.secret_arn
    },
    lookup(var.lambda_config, "environment_variables", {})
  )

  vpc_subnet_ids         = data.aws_subnets.private.ids
  vpc_security_group_ids = [module.security_group.security_group_id]

  provisioning_parameters = var.provisioning_parameters
}

# ──────────────────────────────────────────────
# Lambda Alias (stable invocation endpoint)
# ──────────────────────────────────────────────
module "lambda_alias" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-lambda-alias"

  function_name    = module.lambda.function_name
  function_version = module.lambda.function_version
  alias_name       = "live"
}

# ──────────────────────────────────────────────
# Security Group
# ──────────────────────────────────────────────
module "security_group" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-security-group"

  name        = "${var.env}-${var.lambda_config.name}-sg"
  description = "Security group for ${var.lambda_config.name} Lambda"
  vpc_id      = var.vpc_id

  # Outbound only — Lambda initiates all connections (HTTPS to AWS APIs)
  egress_rules = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTPS egress to AWS service endpoints"
    }
  ]

  provisioning_parameters = var.provisioning_parameters
}

# ──────────────────────────────────────────────
# IAM Role + least-privilege policy
# ──────────────────────────────────────────────
module "lambda_role" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-iam-role"

  name                = "${var.env}-${var.lambda_config.name}-role"
  assume_role_service = "lambda.amazonaws.com"

  inline_policies = {
    SecretsAccess = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadSecret"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = [module.secrets_manager.secret_arn]
        },
        {
          Sid    = "DecryptSecret"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey"
          ]
          Resource = [module.kms.key_arn]
        }
      ]
    })

    CloudWatchLogs = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "WriteLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.lambda_config.name}:*"
        }
      ]
    })

    VpcNetworking = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "ManageNetworkInterfaces"
          Effect = "Allow"
          Action = [
            "ec2:CreateNetworkInterface",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DeleteNetworkInterface"
          ]
          Resource = "*"
        }
      ]
    })
  }

  provisioning_parameters = var.provisioning_parameters
}

# ──────────────────────────────────────────────
# KMS — envelope encryption for the secret
# ──────────────────────────────────────────────
module "kms" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-kms"

  description         = "KMS key for ${var.lambda_config.name}"
  enable_key_rotation = true

  key_usage             = "ENCRYPT_DECRYPT"
  is_enabled            = true
  enable_default_policy = true

  key_owners         = [data.aws_caller_identity.current.arn]
  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn, module.lambda_role.role_arn]

  aliases = ["lambda-monday-logs"]

  provisioning_parameters = var.provisioning_parameters
}

# ──────────────────────────────────────────────
# Secrets Manager — stores Monday.com API key
# ──────────────────────────────────────────────
module "secrets_manager" {
  source = "git::https://github.com/your-org/terraform-modules//terraform-aws-secrets-manager"

  name                    = local.secret_name
  description             = "${var.lambda_config.name} secret"
  recovery_window_in_days = 0
  create_policy           = true
  block_public_policy     = true

  kms_key_id = module.kms.key_arn

  provisioning_parameters = var.provisioning_parameters
}
