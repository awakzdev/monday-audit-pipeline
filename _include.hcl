terraform {
  # NOTE: This path references the internal monorepo structure.
  # When using this module standalone, replace the source with a direct path:
  # source = "${get_repo_root()}///"
  source = "${get_repo_root()}/layers/shared-services-layers/monday-logs-retrieval/${basename(get_terragrunt_dir())}///"
}

locals {
  ## Environment Variables
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals
}

inputs = {
  env      = local.region_vars.env
  env_type = local.region_vars.env_type

  vpc_id = local.region_vars.existing_vpc_id

  lambda_config = {
    name                    = "monday-logs-retrieval"
    timeout                 = 30
    memory_size             = 256
    ephemeral_storage_size  = 512
    ignore_source_code_hash = false

    # Code packaging
    package_type = "Zip"
    filename     = "code.zip"
    handler      = "index.handler"
    runtime      = "python3.11"
  }

  provisioning_parameters = local.region_vars.provisioning_parameters
}
