terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  table_name   = "${var.project_name}-${var.environment}-items"
  function_name = "${var.project_name}-${var.environment}-handler"
  api_name     = "${var.project_name}-${var.environment}-api"
}

# DynamoDB Table
resource "aws_dynamodb_table" "items" {
  name           = local.table_name
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "PK"
  range_key      = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery_specification {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "prod" ? true : false

  server_side_encryption_specification {
    enabled = true
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = {
    Name = local.table_name
  }
}

# Lambda Execution Role
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Lambda Policy for DynamoDB
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project_name}-${var.environment}-lambda-dynamodb"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ]
      Resource = aws_dynamodb_table.items.arn
    }]
  })
}

# Lambda Policy for CloudWatch Logs
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${var.project_name}-${var.environment}-lambda-logs"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.function_name}*"
    }]
  })
}

# Lambda Policy for X-Ray
resource "aws_iam_role_policy" "lambda_xray" {
  name = "${var.project_name}-${var.environment}-lambda-xray"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords"
      ]
      Resource = "*"
    }]
  })
}

# Lambda Function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../apps/dist"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_lambda_function" "handler" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = local.function_name
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs20.x"
  architectures   = ["arm64"]
  timeout         = 10
  memory_size     = 512

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.items.name
      ENVIRONMENT    = var.environment
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda_logs.name
  }

  tracing_config {
    mode = "Active"
  }
}

# Lambda Alias
resource "aws_lambda_alias" "live" {
  name            = "live"
  description     = "Live alias for ${local.function_name}"
  function_name   = aws_lambda_function.handler.function_name
  function_version = aws_lambda_function.handler.version
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/aws/lambda/${local.function_name}"
  }
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "http_api" {
  name          = local.api_name
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = var.cors_allowed_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }

  tags = {
    Name = local.api_name
  }
}

# API Gateway Integration
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_method = "POST"
  payload_format_version = "2.0"
  target = aws_lambda_function.handler.arn
}

# API Gateway Lambda Permission
resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_alias.live.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*"
  qualifier     = aws_lambda_alias.live.name
}

# API Gateway Routes
resource "aws_apigatewayv2_route" "items_get" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "items_post" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "item_get" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "item_put" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "PUT /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "item_delete" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "DELETE /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# API Gateway Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = var.environment
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      sourceIp       = "$context.identity.sourceIp"
      userAgent      = "$context.identity.userAgent"
      requestTime    = "$context.requestTime"
      responseLatency = "$context.responseLatency"
    })
  }

  tags = {
    Name = "${local.api_name}-${var.environment}"
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${local.api_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/aws/apigateway/${local.api_name}"
  }
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.function_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "60"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "Alert when Lambda errors exceed threshold"
  dimensions = {
    FunctionName = aws_lambda_function.handler.function_name
  }
}

data "aws_caller_identity" "current" {}