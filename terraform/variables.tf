variable "aws_region" {
  type        = string
  default     = "ap-northeast-1"
  description = "AWS region"
}

variable "environment" {
  type        = string
  description = "Environment name (dev/prd)"
  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment must be dev or prd"
  }
}

variable "app_name" {
  type        = string
  default     = "serverless-api"
  description = "Application name"
}

variable "stage_name" {
  type        = string
  default     = "default"
  description = "API Gateway stage name"
}

variable "lambda_memory" {
  type        = number
  default     = 512
  description = "Lambda memory allocation in MB"
}

variable "lambda_timeout" {
  type        = number
  default     = 10
  description = "Lambda timeout in seconds"
}

variable "cors_allowed_origins" {
  type        = string
  default     = "*"
  description = "CORS allowed origins"
}

variable "api_burst_limit" {
  type        = number
  default     = 200
  description = "API Gateway burst limit"
}

variable "api_rate_limit" {
  type        = number
  default     = 100
  description = "API Gateway rate limit (requests per second)"
}

variable "log_retention_days" {
  type        = number
  default     = 7
  description = "CloudWatch log retention in days"
}