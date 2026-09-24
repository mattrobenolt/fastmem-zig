# Offline checks of the reaper: the schedule, the function, and the scope of
# its role. reaper/test_reaper.py tests the decision logic.
# Run: tofu -chdir=infra/modules/bench-iam test

variables {
  project           = "fastmem-bench"
  region            = "us-west-2"
  account_id        = "396684171460"
  instance_families = ["c8g"]
}

mock_provider "archive" {}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::396684171460:policy/fastmem-bench-ec2"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::396684171460:role/fastmem-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:396684171460:log-group:/aws/lambda/fastmem-bench-reaper"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-west-2:396684171460:function:fastmem-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-west-2:396684171460:rule/fastmem-bench-reaper"
    }
  }
}

run "reaper" {
  command = plan

  # Every 5 minutes, and EventBridge can invoke the function from this rule
  # only.
  assert {
    condition = (
      aws_cloudwatch_event_rule.reaper.schedule_expression == "rate(5 minutes)"
      && aws_cloudwatch_event_target.reaper.arn == aws_lambda_function.reaper.arn
      && aws_cloudwatch_event_target.reaper.rule == aws_cloudwatch_event_rule.reaper.name
      && aws_lambda_permission.reaper.principal == "events.amazonaws.com"
      && aws_lambda_permission.reaper.action == "lambda:InvokeFunction"
      && aws_lambda_permission.reaper.source_arn == aws_cloudwatch_event_rule.reaper.arn
    )
    error_message = "The reaper must run every 5 minutes from its EventBridge rule."
  }

  assert {
    condition = (
      startswith(aws_lambda_function.reaper.runtime, "python3.")
      && tonumber(split(".", aws_lambda_function.reaper.runtime)[1]) >= 13
      && aws_lambda_function.reaper.handler == "reaper.handler"
      && aws_lambda_function.reaper.role == aws_iam_role.reaper.arn
      && endswith(data.archive_file.reaper.source_file, "/reaper/reaper.py")
    )
    error_message = "The reaper must run reaper.handler on Python 3.13 or later with its own role."
  }

  assert {
    condition = aws_lambda_function.reaper.environment[0].variables == tomap({
      PROJECT              = "fastmem-bench"
      REGION               = "us-west-2"
      MAX_LIFETIME_SECONDS = "86400"
      DRY_RUN              = "false"
    })
    error_message = "The reaper defaults must be: 24 hours maximum lifetime, not a dry run."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.reaper.name == "/aws/lambda/fastmem-bench-reaper"
      && aws_cloudwatch_log_group.reaper.retention_in_days == 30
      && aws_lambda_function.reaper.logging_config[0].log_group == aws_cloudwatch_log_group.reaper.name
    )
    error_message = "The reaper must log to its own log group with a retention."
  }

  assert {
    condition     = jsondecode(aws_iam_role.reaper.assume_role_policy).Statement[0].Principal == { Service = "lambda.amazonaws.com" }
    error_message = "Only Lambda can assume the reaper role."
  }

  # Role scope: Describe on "*", mutations only on project resources in the
  # fleet region, logs only on the reaper log group. Nothing else.
  assert {
    condition = toset(flatten([for s in local.reaper_policy.Statement : s.Action])) == toset([
      "ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeNetworkInterfaces",
      "ec2:TerminateInstances", "ec2:ModifyInstanceAttribute",
      "ec2:DeleteVolume", "ec2:DeleteNetworkInterface", "ec2:CreateTags",
      "logs:CreateLogStream", "logs:PutLogEvents",
    ])
    error_message = "The reaper role allows an unexpected action."
  }

  assert {
    condition = alltrue([
      for s in local.reaper_policy.Statement :
      s.Effect == "Allow" && (
        alltrue([for a in flatten([s.Action]) : startswith(a, "ec2:Describe")]) ? s.Resource == "*" :
        alltrue([for a in flatten([s.Action]) : startswith(a, "logs:")]) ? s.Resource == "arn:aws:logs:us-west-2:396684171460:log-group:/aws/lambda/fastmem-bench-reaper:*" :
        (
          try(s.Condition.StringEquals, null) == { "aws:ResourceTag/Project" = "fastmem-bench" }
          && alltrue([for r in flatten([s.Resource]) : startswith(r, "arn:aws:ec2:us-west-2:396684171460:")])
        )
      )
    ])
    error_message = "A reaper statement is wider than Describe, project resources, or its own log group."
  }

  # The only tag that the reaper writes is its orphan mark.
  assert {
    condition     = one([for s in local.reaper_policy.Statement : s.Condition["ForAllValues:StringEquals"]["aws:TagKeys"] if contains(flatten([s.Action]), "ec2:CreateTags")]) == ["OrphanSeenAt"]
    error_message = "The reaper can write a tag other than OrphanSeenAt."
  }
}

run "dry_run" {
  command = plan

  variables {
    reaper_dry_run            = true
    reaper_max_lifetime_hours = 6
    reaper_log_retention_days = 7
  }

  assert {
    condition = (
      aws_lambda_function.reaper.environment[0].variables.DRY_RUN == "true"
      && aws_lambda_function.reaper.environment[0].variables.MAX_LIFETIME_SECONDS == "21600"
      && aws_cloudwatch_log_group.reaper.retention_in_days == 7
    )
    error_message = "The reaper variables do not reach the function and the log group."
  }
}

run "rejects_fractional_lifetime" {
  command = plan

  variables {
    reaper_max_lifetime_hours = 0.5
  }

  expect_failures = [var.reaper_max_lifetime_hours]
}
