resource "aws_security_group" "guacamole_alb_sg" {
  name   = "${local.resource_name}-guacamole-alb-sg"
  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-alb-sg"
  })

  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_lb" "guacamole_alb" {
  name               = "${local.resource_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.guacamole_alb_sg.id]
  subnets            = local.guac_public_subnet_ids


  access_logs {
    bucket  = local.lb_access_logs_bucket_name
    prefix  = "access"
    enabled = true
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-alb"
  })
}

resource "aws_lb_target_group" "guacamole_tg" {
  name                          = "${local.resource_name}-tg"
  port                          = 443
  protocol                      = "HTTPS"
  vpc_id                        = local.vpc_id
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    port                = 443
    protocol            = "HTTPS"
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-guacamole-tg"
  })
}


resource "aws_lb_listener" "guac_listner_https" {
  load_balancer_arn = aws_lb.guacamole_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = local.guac_alb_certificate_arn
  ssl_policy        = local.guac_alb_ssl_policy

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.guacamole_tg.arn
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-alb-listener"
  })
}

resource "aws_lb_listener" "guac_listner_http" {
  load_balancer_arn = aws_lb.guacamole_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-alb-listener"
  })
}

resource "aws_lb_target_group_attachment" "guac_ec2_attach" {
  for_each         = { for idx, instance in aws_instance.guacamole : idx => instance }
  depends_on       = [aws_lb_target_group.guacamole_tg]
  target_group_arn = aws_lb_target_group.guacamole_tg.arn
  target_id        = each.value.id
  port             = 443
}