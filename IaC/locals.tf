locals {
  inputs = yamldecode(file("${path.module}/inputs.yaml"))

  tf_state_bucket_name = local.inputs["tf_state_bucket_name"]
  tf_state_path        = local.inputs["tf_state_path"]

  customer_name = local.inputs["customer_name"]
  customer_org = local.inputs["customer_org"]
  customer_env = local.inputs["customer_env"]
  app_name = local.inputs["app_name"]
  app_version = local.inputs["app_version"]
  aws_region = local.inputs["aws_region"]

  resource_name = replace("${local.customer_name}-${local.customer_org}-${local.customer_env}-${local.app_name}-${local.app_version}", ".", "")

  # VPC Configuration
  vpc_id = local.inputs["vpc_config"]["vpc_id"]
  
  # Get all private and public subnet IDs from vpc_config
  private_subnet_ids = [
    for az, config in local.inputs["vpc_config"]["availability_zones"]:
    config["private_subnet_id"]
  ]
  public_subnet_ids = [
    for az, config in local.inputs["vpc_config"]["availability_zones"]:
    config["public_subnet_id"]
  ]
  
  # Server Configuration
  guac_instance_type = local.inputs["server_config"]["guacamole"]["instance_type"]
  guac_ami = local.inputs["server_config"]["guacamole"]["ami"]
  guac_instance_volume_size = local.inputs["server_config"]["guacamole"]["instance_volume_size"]
  guac_sg_rules = local.inputs["server_config"]["guacamole"]["sg_rules"]
  guac_availability_zones = local.inputs["server_config"]["guacamole"]["availability_zones"]

  # Get Guacamole subnet IDs based on availability zones
  guac_private_subnet_ids = [
    for az in local.guac_availability_zones:
    local.inputs["vpc_config"]["availability_zones"][az]["private_subnet_id"]
  ]
  guac_public_subnet_ids = [
    for az in local.guac_availability_zones:
    local.inputs["vpc_config"]["availability_zones"][az]["public_subnet_id"]
  ]

  # Windows Server Configuration
  windows_instance_type = local.inputs["server_config"]["windows_server"]["instance_type"]
  windows_ami = local.inputs["server_config"]["windows_server"]["ami"]
  windows_instance_volume_size = local.inputs["server_config"]["windows_server"]["instance_volume_size"]
  windows_sg_rules = local.inputs["server_config"]["windows_server"]["sg_rules"]
  windows_asg_min_size = local.inputs["server_config"]["windows_server"]["asg_min_size"]
  windows_asg_max_size = local.inputs["server_config"]["windows_server"]["asg_max_size"]
  windows_asg_desired_capacity = local.inputs["server_config"]["windows_server"]["asg_desired_capacity"]
  windows_asg_availability_zones = local.inputs["server_config"]["windows_server"]["availability_zones"]

  # Get Windows subnet IDs based on availability zones
  windows_private_subnet_ids = [
    for az in local.windows_asg_availability_zones:
    local.inputs["vpc_config"]["availability_zones"][az]["private_subnet_id"]
  ]
  windows_public_subnet_ids = [
    for az in local.windows_asg_availability_zones:
    local.inputs["vpc_config"]["availability_zones"][az]["public_subnet_id"]
  ]

  tags = local.inputs["tags"]
}
