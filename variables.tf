variable "env" {
  description = "Environment name (e.g. shared-services, staging, prod)"
  type        = string
}

variable "env_type" {
  description = "Environment type used for subnet tag filtering (e.g. prod, non-prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC in which the Lambda and its security group will be placed"
  type        = string
}

variable "lambda_config" {
  description = "Configuration block for the Lambda function (name, runtime, handler, memory, etc.)"
  type        = any
}

variable "provisioning_parameters" {
  description = "List of key/value tag objects propagated to all resources for cost allocation and governance"
  type = list(object({
    key   = string
    value = string
  }))
  default = []
}
