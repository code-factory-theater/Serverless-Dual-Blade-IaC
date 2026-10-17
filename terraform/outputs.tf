output "api_endpoint" {
  description = "API Gateway HTTP API endpoint"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/${var.environment}"
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.handler.arn
}

output "lambda_alias_arn" {
  description = "Lambda alias ARN"
  value       = aws_lambda_alias.live.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.items.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.items.arn
}