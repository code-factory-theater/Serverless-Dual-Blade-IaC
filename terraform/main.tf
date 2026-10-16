terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "terraform-state-${var.environment}"
    key            = "serverless-api/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment  = var.environment
      ManagedBy    = "Terraform"
      Project      = "ServerlessAPI"
      CreatedAt    = timestamp()
    }
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name               = "${var.app_name}-lambda-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name   = "${var.app_name}-lambda-dynamodb-policy"
  role   = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.api_table.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_insights" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy"
}

# DynamoDB Table
resource "aws_dynamodb_table" "api_table" {
  name           = "${var.app_name}-table-${var.environment}"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
  point_in_time_recovery_specification {
    enabled = true
  }
  server_side_encryption_specification {
    enabled = true
  }
  tags = {
    Name = "${var.app_name}-table-${var.environment}"
  }
}

# Lambda Function
resource "aws_lambda_function" "api_handler" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name   = "${var.app_name}-handler-${var.environment}"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs.20.x"
  architectures   = ["arm64"]
  memory_size     = var.lambda_memory
  timeout         = var.lambda_timeout
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.api_table.name
      ENVIRONMENT   = var.environment
      LOG_LEVEL     = "INFO"
    }
  }

  layers = [aws_lambda_layer_version.insights.arn]

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_layer_version" "insights" {
  filename            = data.archive_file.layer_zip.output_path
  layer_name          = "${var.app_name}-insights-layer"
  compatible_runtimes = ["nodejs.20.x"]
  source_code_hash    = data.archive_file.layer_zip.output_base64sha256
}

# Dead Letter Queue
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.app_name}-dlq-${var.environment}"
  message_retention_seconds = 1209600
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.app_name}-api-${var.environment}"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = [var.cors_allowed_origins]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = var.stage_name
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationLatency = "$context.integration.latency"
    })
  }

  throttle_settings {
    burst_limit = var.api_burst_limit
    rate_limit  = var.api_rate_limit
  }
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.app_name}-${var.environment}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_method = "POST"
  integration_uri  = aws_lambda_function.api_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# Data sources
data "aws_caller_identity" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../apps/dist"
  output_path = "${path.module}/lambda.zip"
}

data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../node_modules"
  output_path = "${path.module}/layer.zip"
}