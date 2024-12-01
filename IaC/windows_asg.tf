resource "aws_security_group" "windows_sg" {
  name = "${local.resource_name}-windows-sg"
  vpc_id = local.vpc_id
  
  tags = merge(local.tags, {
    Name = "${local.resource_name}-windows-sg"
  })
}

resource "aws_security_group_rule" "windows_ingress" {
  for_each = { for idx, rule in local.windows_sg_rules.ingress : idx => rule }
  type              = "ingress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = [each.value.cidr]
  security_group_id = aws_security_group.windows_sg.id
  depends_on = [ aws_security_group.windows_sg ]
}

resource "aws_security_group_rule" "windows_egress" {
  for_each = { for idx, rule in local.windows_sg_rules.egress : idx => rule }
  type              = "egress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = [each.value.cidr]
  security_group_id = aws_security_group.windows_sg.id
  depends_on = [ aws_security_group.windows_sg ]
}

# IAM Role assume policy document
data "aws_iam_policy_document" "windows_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Custom policy document for Windows instances
data "aws_iam_policy_document" "windows_policy" {
  statement {
    actions = [
      "cloudwatch:Get*",
      "cloudwatch:ListMetrics",
      "autoscaling:CompleteLifecycleAction",
      "secretsmanager:GetSecretValue"
    ]
    resources = ["*"]
    effect    = "Allow"
  }
}

# Create IAM role
resource "aws_iam_role" "windows_role" {
  name               = "${local.resource_name}-windows-role"
  assume_role_policy = data.aws_iam_policy_document.windows_assume_role.json
  
  tags = merge(local.tags, {
    Name = "${local.resource_name}-windows-role"
  })
}

# Attach custom policy to the role
resource "aws_iam_role_policy" "windows_policy" {
  name   = "${local.resource_name}-windows-policy"
  role   = aws_iam_role.windows_role.id
  policy = data.aws_iam_policy_document.windows_policy.json
}

# Attach AmazonEC2RoleforSSM managed policy
resource "aws_iam_role_policy_attachment" "windows_ssm_policy" {
  role       = aws_iam_role.windows_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

# Create instance profile
resource "aws_iam_instance_profile" "windows_profile" {
  name = "${local.resource_name}-windows-profile"
  role = aws_iam_role.windows_role.name

  lifecycle {
    create_before_destroy = false
  }
  
  tags = merge(local.tags, {
    Name = "${local.resource_name}-windows-profile"
  })
}

# Launch template for Windows instances
resource "aws_launch_template" "windows" {
  name = "${local.resource_name}-windows-lt"
  description = "Launch template for Windows instances"
  
  image_id = local.windows_ami
  instance_type = local.windows_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.windows_profile.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups = [aws_security_group.windows_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = local.windows_instance_volume_size
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = aws_kms_key.kms_key.arn
      delete_on_termination = true
    }
  }

  user_data = filebase64("${path.module}/scripts/windows/ActiveUserWatcher.ps1")

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.resource_name}-windows"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.tags, {
      Name = "${local.resource_name}-windows"
    })
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-windows-lt"
  })
}

# Auto Scaling Group
resource "aws_autoscaling_group" "windows" {
  depends_on = [ aws_launch_template.windows ]
  name = "${local.resource_name}-windows-asg"
  
  vpc_zone_identifier = local.windows_private_subnet_ids
  target_group_arns  = []  
  health_check_type  = "EC2"
  health_check_grace_period = 300
  
  min_size = local.windows_asg_min_size
  max_size = local.windows_asg_max_size
  desired_capacity = local.windows_asg_desired_capacity

  launch_template {
    id      = aws_launch_template.windows.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, {
      Name = "${local.resource_name}-windows-#"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [target_group_arns]
  }
}

# CPU Utilization Target Tracking Policy
resource "aws_autoscaling_policy" "cpu_policy" {
  depends_on = [ aws_autoscaling_group.windows ]
  name                   = "${local.resource_name}-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.windows.name
  policy_type           = "TargetTrackingScaling"
  
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 75.0
    disable_scale_in = true
  }
}

# Memory Scale Up Policy
resource "aws_autoscaling_policy" "memory_policy" {
  depends_on = [ aws_autoscaling_group.windows ]
  name                   = "${local.resource_name}-memory-policy"
  autoscaling_group_name = aws_autoscaling_group.windows.name
  policy_type           = "StepScaling"
  adjustment_type       = "ChangeInCapacity"
  
  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 20
  }
  
  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 20
  }
}

# Scale-in policy
resource "aws_autoscaling_policy" "scale_in" {
  depends_on = [ aws_autoscaling_group.windows ]
  name                   = "${local.resource_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.windows.name
  adjustment_type        = "ChangeInCapacity"
  policy_type           = "SimpleScaling"
  scaling_adjustment     = -1
  cooldown              = 300
}

# Lifecycle hook for termination
resource "aws_autoscaling_lifecycle_hook" "termination_hook" {
  depends_on              = [ aws_autoscaling_group.windows ]
  name                    = "${local.resource_name}-termination-hook"
  autoscaling_group_name  = aws_autoscaling_group.windows.name
  lifecycle_transition    = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result         = "ABANDON"
  heartbeat_timeout      = 300
  notification_metadata  = jsonencode({
    "action" = "check_sessions"
  })
}

# CloudWatch Alarm for Memory
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  depends_on          = [ aws_autoscaling_group.windows ]
  alarm_name          = "${local.resource_name}-memory-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Memory % Committed Bytes In Use"
  namespace           = "CWAgent"
  period             = "300"
  statistic          = "Average"
  threshold          = 65
  alarm_description  = "Memory utilization above 65%"
  alarm_actions      = [aws_autoscaling_policy.memory_policy.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.windows.name
  }
}

# CloudWatch Event Rule
resource "aws_cloudwatch_event_rule" "asg_termination" {
  depends_on  = [ aws_autoscaling_group.windows ]
  name        = "${local.resource_name}-asg-termination"
  description = "Capture ASG termination events"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.windows.name]
    }
  })
}

# CloudWatch Event Target
resource "aws_cloudwatch_event_target" "lambda" {
  depends_on = [ aws_cloudwatch_event_rule.asg_termination, aws_lambda_function.check_sessions ]
  rule      = aws_cloudwatch_event_rule.asg_termination.name
  target_id = "CheckSessions"
  arn       = aws_lambda_function.check_sessions.arn
}

# Lambda permission for CloudWatch Events
resource "aws_lambda_permission" "allow_eventbridge" {
  depends_on    = [ aws_cloudwatch_event_rule.asg_termination, aws_lambda_function.check_sessions ]
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_sessions.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.asg_termination.arn
}