# Fetch datadog api key
data "aws_secretsmanager_secret_version" "datadog_api_key" {
  secret_id = local.datadog_api_key_secret
}

locals {
  datadog_api_key = jsondecode(data.aws_secretsmanager_secret_version.datadog_api_key.secret_string)["api_key"]
}

resource "aws_security_group" "guacamole_sg" {
  name = "${local.resource_name}-guacamole-sg"
  vpc_id = local.vpc_id
  
  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-sg"
  })
}

resource "aws_security_group_rule" "guacamole_ingress" {
  for_each = { for idx, rule in local.guac_sg_rules.ingress : idx => rule }
  type              = "ingress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = [each.value.cidr]
  security_group_id = aws_security_group.guacamole_sg.id
  depends_on = [ aws_security_group.guacamole_sg ]
}

resource "aws_security_group_rule" "guacamole_egress" {
  for_each = { for idx, rule in local.guac_sg_rules.egress : idx => rule }
  type              = "egress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = [each.value.cidr]
  security_group_id = aws_security_group.guacamole_sg.id
  depends_on = [ aws_security_group.guacamole_sg ]
}

# IAM Role for Guacamole Instances
resource "aws_iam_role" "guacamole_role" {
  name = "${local.resource_name}-guacamole-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-role"
  })

  # Add lifecycle to prevent recreation
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Attach SSM Managed Instance Core policy
resource "aws_iam_role_policy_attachment" "ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.guacamole_role.name
}

# Additional SSM-related policies
resource "aws_iam_role_policy_attachment" "ssm_additional" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
  role       = aws_iam_role.guacamole_role.name
}

# Additional EC2 and Systems Manager policies
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
  role       = aws_iam_role.guacamole_role.name
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "guacamole_profile" {
  name = "${local.resource_name}-guacamole-profile"
  role = aws_iam_role.guacamole_role.name

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-profile"
  })

  # Add lifecycle to prevent recreation
  lifecycle {
    create_before_destroy = true
  }
}

# Custom policy document for guacamole instances
data "aws_iam_policy_document" "guacamole_policy" {
  statement {
    actions = [
      "cloudwatch:Get*",
      "cloudwatch:ListMetrics",
      "autoscaling:CompleteLifecycleAction",
      "secretsmanager:GetSecretValue",
      "ec2:DescribeTags",
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]
    resources = ["*"]
    effect    = "Allow"
  }
}

# Attach custom policy to the role
resource "aws_iam_role_policy" "guacamole_policy" {
  name   = "${local.resource_name}-guacamole-policy"
  role   = aws_iam_role.guacamole_role.id
  policy = data.aws_iam_policy_document.guacamole_policy.json
}

# Launch template for Guacamole instances
resource "aws_launch_template" "guacamole" {
  name          = "${local.resource_name}-guacamole-lt"
  image_id      = local.guac_ami
  instance_type = local.guac_instance_type
  key_name = aws_key_pair.windows_key_pair.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.guacamole_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = local.guac_instance_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/guacamole/startup.sh", {
    customer_name = local.customer_name
    customer_org  = local.customer_org
    customer_env  = local.customer_env
    ad_domain     = local.ad_domain
    datadog_api_key = local.datadog_api_key
    app_name = local.app_name
  }))

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-lt"
  })
}

# Guacamole Instances
resource "aws_instance" "guacamole" {
  for_each = toset(local.guac_availability_zones)

  launch_template {
    id      = aws_launch_template.guacamole.id
    version = "$Latest"
  }

  # Use index of the AZ to get corresponding subnet ID
  subnet_id = local.guac_private_subnet_ids[index(local.guac_availability_zones, each.key)]

  vpc_security_group_ids = [aws_security_group.guacamole_sg.id]

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-${substr(each.key, -1, 1)}"
    AvailabilityZone = each.key
  })
}
