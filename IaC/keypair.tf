resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "aws_key_pair" "windows_key_pair" {
  key_name   = "${local.resource_name}-key"
  public_key = tls_private_key.key.public_key_openssh
  tags = merge(local.tags, {
    Name = "${local.resource_name}-key"
  })
}

resource "local_file" "key" {
  content         = tls_private_key.key.private_key_pem
  filename        = pathexpand("~/.ssh/${local.resource_name}-key.pem")
  file_permission = "0600"
}

resource "aws_ssm_parameter" "aws_key_pair" {
  name        = "${local.resource_name}-key"
  description = "SSH key for ${local.resource_name}"
  type        = "SecureString"
  value       = tls_private_key.key.private_key_pem

  tags = merge(local.tags, {
    Name = "${local.resource_name}-private-key"
  })
}