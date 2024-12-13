locals {
  rds_monitoring_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/rds-monitoring-role"
  rds_creds               = jsondecode(data.aws_secretsmanager_secret_version.rds_credentials.secret_string)
}

data "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = local.rds_config.rds_secret_name
}

data "aws_iam_role" "monitoring_role" {
  name = "rds-monitoring-role"
}

resource "aws_security_group" "rds_sg" {
  name        = "${local.resource_name}-rds-sg"
  description = "Security group for Aurora RDS cluster"
  vpc_id      = local.vpc_id

  # Allow access from Windows instances
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.windows_sg.id]
  }

  # Allow access from my IP for development
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [yamldecode(file("${path.module}/inputs.yaml")).my_ip]
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-rds-sg"
  })
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.resource_name}-aurora-subnet-group"
  subnet_ids = local.private_subnet_ids

  tags = merge(local.tags, {
    Name = "${local.resource_name}-aurora-subnet-group"
  })
}

resource "aws_rds_cluster" "aurora_cluster" {
  cluster_identifier = "${local.resource_name}-psql"
  engine             = local.rds_config.engine
  engine_version     = local.rds_config.engine_version
  availability_zones = local.rds_config.availability_zones
  database_name      = local.rds_config.database_name
  master_username    = local.rds_creds.db_username
  master_password    = local.rds_creds.db_password

  serverlessv2_scaling_configuration {
    min_capacity = local.rds_config.acu_min
    max_capacity = local.rds_config.acu_max
  }

  # performance
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.kms_key.arn

  iam_database_authentication_enabled = false
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.kms_key.arn

  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.aurora.id
  port                   = 5432

  # deletion
  deletion_protection             = true
  enabled_cloudwatch_logs_exports = []

  # storage
  storage_type = "aurora-iopt1"
  # backup
  backup_retention_period = 7
  skip_final_snapshot     = true
  copy_tags_to_snapshot   = true

  tags = merge(local.tags, {
    Name = "${local.resource_name}-psql"
  })

  lifecycle {
    ignore_changes = [
      availability_zones, # Ignore changes to availability zones
      allocated_storage,  # Ignore allocated storage changes
      apply_immediately   # Ignore immediate apply flag
    ]
  }
}

resource "aws_rds_cluster_instance" "aurora_instances" {
  count              = length(local.rds_config.availability_zones)
  identifier         = "${local.resource_name}-cluster-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora_cluster.id
  instance_class     = "db.serverless" # Serverless v2 instance class
  engine             = aws_rds_cluster.aurora_cluster.engine
  engine_version     = aws_rds_cluster.aurora_cluster.engine_version

  monitoring_interval = 60
  monitoring_role_arn = local.rds_monitoring_role_arn

  auto_minor_version_upgrade = false

  publicly_accessible   = false
  copy_tags_to_snapshot = true

  tags = merge(local.tags, {
    Name = "${local.resource_name}-aurora-cluster-${count.index + 1}"
  })
}

# Update only the secret version with additional RDS information
resource "aws_secretsmanager_secret_version" "rds_connection_details" {
  secret_id = local.rds_config.rds_secret_name
  secret_string = jsonencode(merge(
    jsondecode(data.aws_secretsmanager_secret_version.rds_credentials.secret_string),
    {
      db_endpoint   = aws_rds_cluster.aurora_cluster.endpoint
      db_port       = aws_rds_cluster.aurora_cluster.port
      db_identifier = aws_rds_cluster.aurora_cluster.cluster_identifier
      dbname        = local.rds_config.database_name
      engine        = local.rds_config.engine
    }
  ))

  lifecycle {
    ignore_changes = [
      # Ignore changes to secret_string to prevent overwriting manual updates
      secret_string
    ]
  }
}

# Download and apply Guacamole schema
resource "null_resource" "create_guacamole_schema" {
  triggers = {
    cluster_endpoint = aws_rds_cluster.aurora_cluster.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Download schema file
      curl -o /tmp/guacamole-schema.sql https://raw.githubusercontent.com/glyptodon/guacamole-client/master/extensions/guacamole-auth-jdbc/modules/guacamole-auth-jdbc-postgresql/schema/001-create-schema.sql
      
      # Apply schema
      PGPASSWORD='${aws_rds_cluster.aurora_cluster.master_password}' psql \
        -h ${aws_rds_cluster.aurora_cluster.endpoint} \
        -p ${aws_rds_cluster.aurora_cluster.port} \
        -U ${aws_rds_cluster.aurora_cluster.master_username} \
        -d ${aws_rds_cluster.aurora_cluster.database_name} \
        -f /tmp/guacamole-schema.sql

      # Clean up
      rm -f /tmp/guacamole-schema.sql
    EOT
  }

  depends_on = [
    aws_rds_cluster.aurora_cluster,
    aws_rds_cluster_instance.aurora_instances
  ]
}

# Download and create admin user
resource "null_resource" "create_guacamole_admin_user" {
  triggers = {
    cluster_endpoint = aws_rds_cluster.aurora_cluster.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Download schema file
      curl -o /tmp/create-admin-user.sql https://raw.githubusercontent.com/glyptodon/guacamole-client/refs/heads/master/extensions/guacamole-auth-jdbc/modules/guacamole-auth-jdbc-postgresql/schema/002-create-admin-user.sql
      
      # Apply schema
      PGPASSWORD='${aws_rds_cluster.aurora_cluster.master_password}' psql \
        -h ${aws_rds_cluster.aurora_cluster.endpoint} \
        -p ${aws_rds_cluster.aurora_cluster.port} \
        -U ${aws_rds_cluster.aurora_cluster.master_username} \
        -d ${aws_rds_cluster.aurora_cluster.database_name} \
        -f /tmp/create-admin-user.sql

      # Clean up
      rm -f /tmp/create-admin-user.sql
    EOT
  }

  depends_on = [
    aws_rds_cluster.aurora_cluster,
    aws_rds_cluster_instance.aurora_instances
  ]
}
