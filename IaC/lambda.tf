# IAM role for Lambda function
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Lambda execution role
resource "aws_iam_role" "lambda_role" {
  name               = "${local.resource_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = merge(local.tags, {
    Name = "${local.resource_name}-lambda-role"
  })
}

# Lambda policy
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:RecordLifecycleActionHeartbeat"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${local.resource_name}-lambda-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# Create zip file for Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/scripts/lambda/check_active_sessions.py"
  output_path = "${path.module}/scripts/lambda/check_active_sessions.zip"
}

# Lambda function
resource "aws_lambda_function" "check_sessions" {
  depends_on = [ aws_autoscaling_group.windows ]
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.resource_name}-check-sessions"
  role            = aws_iam_role.lambda_role.arn
  handler         = "check_active_sessions.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime         = "python3.9"
  timeout         = 300
  memory_size     = 128

  environment {
    variables = {
      ASG_NAME = aws_autoscaling_group.windows.name
    }
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name}-check-sessions"
  })
}