output "api_endpoint" {
  value       = "${aws_apigatewayv2_api.api.api_endpoint}/"
  description = "API Gateway HTTP API endpoint"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.api_table.name
  description = "DynamoDB table name"
}

output "lambda_function_name" {
  value       = aws_lambda_function.api_handler.function_name
  description = "Lambda function name"
}

output "cloudwatch_log_group" {
  value       = aws_cloudwatch_log_group.lambda_logs.name
  description = "CloudWatch log group for Lambda"
}