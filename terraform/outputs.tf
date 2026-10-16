output "api_endpoint" {
  value       = aws_apigatewayv2_api.http_api.api_endpoint
  description = "HTTP API endpoint URL"
}

output "api_id" {
  value       = aws_apigatewayv2_api.http_api.id
  description = "API Gateway ID"
}

output "lambda_function_name" {
  value       = aws_lambda_function.api_handler.function_name
  description = "Lambda function name"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.api_table.name
  description = "DynamoDB table name"
}

output "lambda_role_arn" {
  value       = aws_iam_role.lambda_role.arn
  description = "Lambda IAM role ARN"
}

output "dlq_url" {
  value       = aws_sqs_queue.dlq.url
  description = "Dead Letter Queue URL"
}