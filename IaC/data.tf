# data "aws_secretsmanager_secret" "rds_credentials" {
#   name = "${local.resource_name}-rds-creds2"
# }

# data "aws_secretsmanager_secret_version" "rds_credentials" {
#   secret_id = data.aws_secretsmanager_secret.rds_credentials.id
# }