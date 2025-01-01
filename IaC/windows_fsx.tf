
data "aws_secretsmanager_secret_version" "ad_domain_creds" {
  secret_id = local.ad_credentials_secret
}

locals {
  ad_creds = jsondecode(data.aws_secretsmanager_secret_version.ad_domain_creds.secret_string)
}

resource "aws_security_group" "fsx_sg" {
  name        = "${local.resource_name}-fsx-sg"
  description = "Security group for FSx file system"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-fsx-sg"
  })
}

resource "aws_fsx_windows_file_system" "windows_fsx" {
  subnet_ids = local.windows_private_subnet_ids
  security_group_ids = [aws_security_group.fsx_sg.id]
  kms_key_id = aws_kms_key.kms_key.arn
  storage_capacity    = local.fsx_size
  throughput_capacity = local.fsx_throughput
  self_managed_active_directory {
    dns_ips = local.ad_domain_ips
    domain_name = local.ad_domain
    password = local.ad_creds["Password"]
    username = local.ad_creds["UserId"]
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-fsx"
  })
}
