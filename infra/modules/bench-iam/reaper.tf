# The reaper: the lifetime guarantee of the fleet.
#
# The bench user writes the launch templates, so it controls what runs on a
# box, the TTL guard included, and it can write any ExpiresAt value. This
# Lambda function runs outside the boxes with its own role. The bench user
# cannot change it: the bench policy grants no Lambda, EventBridge, IAM, or
# CloudWatch Logs action.
#
# EventBridge invokes the function every 5 minutes. reaper/reaper.py holds
# the rules, and reaper/test_reaper.py tests them.

locals {
  reaper_name = "${var.project}-reaper"
}

# The zip goes under .terraform of the root stack, which git ignores.
data "archive_file" "reaper" {
  type             = "zip"
  source_file      = "${path.module}/reaper/reaper.py"
  output_path      = "${path.root}/.terraform/tmp/${local.reaper_name}.zip"
  output_file_mode = "0644"
}

# The function writes its logs here. Lambda creates the group with no
# retention if it is absent, and the role has no logs:CreateLogGroup, so the
# group must exist first.
resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/${local.reaper_name}"
  retention_in_days = var.reaper_log_retention_days
}

resource "aws_iam_role" "reaper" {
  name        = local.reaper_name
  description = "Execution role of the ${local.reaper_name} Lambda function"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

locals {
  project_tag = { StringEquals = { "aws:ResourceTag/Project" = var.project } }

  reaper_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Describe actions support no resource-level permissions.
        Sid      = "Read"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
      {
        # ModifyInstanceAttribute removes termination protection
        # (DisableApiTermination), which a launch template or a request of the
        # bench user can set.
        Sid       = "TerminateProjectInstances"
        Effect    = "Allow"
        Action    = ["ec2:TerminateInstances", "ec2:ModifyInstanceAttribute"]
        Resource  = "${local.ec2}:instance/*"
        Condition = local.project_tag
      },
      {
        # Volumes and network interfaces that outlive their instance
        # (DeleteOnTermination = false).
        Sid       = "DeleteProjectOrphans"
        Effect    = "Allow"
        Action    = ["ec2:DeleteVolume", "ec2:DeleteNetworkInterface"]
        Resource  = ["${local.ec2}:volume/*", "${local.ec2}:network-interface/*"]
        Condition = local.project_tag
      },
      {
        # The OrphanSeenAt mark on an available network interface, and no
        # other tag.
        Sid      = "MarkOrphanInterfaces"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2}:network-interface/*"
        Condition = merge(local.project_tag, {
          "ForAllValues:StringEquals" = { "aws:TagKeys" = ["OrphanSeenAt"] }
        })
      },
      {
        # Its own log group only.
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.reaper.arn}:*"
      },
    ]
  }
}

resource "aws_iam_role_policy" "reaper" {
  name   = local.reaper_name
  role   = aws_iam_role.reaper.id
  policy = jsonencode(local.reaper_policy)
}

resource "aws_lambda_function" "reaper" {
  function_name    = local.reaper_name
  description      = "Terminates expired ${var.project} instances and deletes their orphan volumes and network interfaces"
  role             = aws_iam_role.reaper.arn
  runtime          = "python3.14"
  architectures    = ["arm64"]
  handler          = "reaper.handler"
  filename         = data.archive_file.reaper.output_path
  source_code_hash = data.archive_file.reaper.output_base64sha256
  memory_size      = 128
  timeout          = 120

  environment {
    variables = {
      PROJECT              = var.project
      REGION               = var.region
      MAX_LIFETIME_SECONDS = tostring(var.reaper_max_lifetime_hours * 3600)
      DRY_RUN              = tostring(var.reaper_dry_run)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.reaper.name
  }

  # The first scheduled run must have its permissions.
  depends_on = [aws_iam_role_policy.reaper]
}

resource "aws_cloudwatch_event_rule" "reaper" {
  name                = local.reaper_name
  description         = "Invoke ${local.reaper_name} every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "reaper" {
  rule = aws_cloudwatch_event_rule.reaper.name
  arn  = aws_lambda_function.reaper.arn
}

resource "aws_lambda_permission" "reaper" {
  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reaper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reaper.arn
}
