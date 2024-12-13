# Auto Scaling Group outputs
output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.windows.name
}

# Launch Template outputs
output "launch_template_id" {
  description = "ID of the Launch Template"
  value       = aws_launch_template.windows.id
}

# KMS outputs
output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.kms_key.key_id
}

output "kms_key_alias" {
  description = "Alias of the KMS key"
  value       = aws_kms_alias.key_alias.name
}

# Security Group outputs
output "windows_security_group_id" {
  description = "ID of the Windows instances security group"
  value       = aws_security_group.windows_sg.id
}

# IAM Role outputs
output "windows_role_name" {
  description = "Name of the Windows instances IAM role"
  value       = aws_iam_role.windows_role.name
}

# Lambda outputs
output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.check_sessions.function_name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = aws_iam_role.lambda_role.arn
}

output "windows_nlb_dns_name" {
  description = "DNS name of the Windows instances NLB"
  value       = aws_lb.windows_nlb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint of the RDS cluster"
  value       = aws_rds_cluster.aurora_cluster.endpoint
}

output "rds_identifier" {
  description = "Identifier of the RDS cluster"
  value       = aws_rds_cluster.aurora_cluster.cluster_identifier
}

output "guacamole_servers" {
  value = values(aws_instance.guacamole)[*].id
}

output "guacamole_iam_role" {
  value = aws_iam_role.guacamole_role.arn
}

output "guacamole_alb_dns_name" {
  value = aws_lb.guacamole_alb.dns_name
}