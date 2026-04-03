data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:environment-name"
    values = [var.env]
  }

  filter {
    name   = "tag:environment-type"
    values = [var.env_type]
  }

  filter {
    name   = "tag:Name"
    values = ["*private-app*"]
  }
}
