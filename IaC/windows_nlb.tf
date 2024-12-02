# Network Load Balancer
resource "aws_lb" "windows_nlb" {
  name               = "${local.resource_name}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = local.windows_private_subnet_ids

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  access_logs {
    bucket  = local.lb_access_logs_bucket_name
    prefix  = "access"
    enabled = true
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-nlb"
  })
}

# Target Group for RDP
resource "aws_lb_target_group" "rdp" {
  name        = "${local.resource_name}-rdp-tg"
  port        = 3389
  protocol    = "TCP"
  vpc_id      = local.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port               = 3389
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  stickiness {
    enabled = true
    type    = "source_ip"
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-rdp-tg"
  })
}

# Listener for RDP
resource "aws_lb_listener" "rdp" {
  load_balancer_arn = aws_lb.windows_nlb.arn
  port              = 3389
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rdp.arn
  }
}

# Target Group Attachment
resource "aws_autoscaling_attachment" "rdp" {
  depends_on             = [ aws_autoscaling_group.windows ]
  autoscaling_group_name = aws_autoscaling_group.windows.name
  lb_target_group_arn    = aws_lb_target_group.rdp.arn
}