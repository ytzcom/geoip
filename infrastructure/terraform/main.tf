terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "s3_bucket_name" {
  description = "S3 bucket name for GeoIP databases"
  type        = string
  default     = "ytz-geoip"
}

# DynamoDB table for API keys
resource "aws_dynamodb_table" "api_keys" {
  name           = "geoip-api-keys"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "api_key_hash"
  
  attribute {
    name = "api_key_hash"
    type = "S"
  }
  
  attribute {
    name = "request_time"
    type = "N"
  }
  
  # Global secondary index for rate limiting queries
  global_secondary_index {
    name            = "api_key_requests"
    hash_key        = "api_key_hash"
    range_key       = "request_time"
    projection_type = "ALL"
  }
  
  tags = {
    Name        = "geoip-api-keys"
    Environment = var.environment
  }
}

# Lambda execution role
resource "aws_iam_role" "lambda_role" {
  name = "geoip-auth-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda policy
resource "aws_iam_role_policy" "lambda_policy" {
  name = "geoip-auth-lambda-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.api_keys.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.request_logs.arn,
          "${aws_dynamodb_table.api_keys.arn}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/*"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "auth" {
  filename         = "lambda_function.zip"
  function_name    = "geoip-auth"
  role            = aws_iam_role.lambda_role.arn
  handler         = "auth_handler.lambda_handler"
  source_code_hash = filebase64sha256("lambda_function.zip")
  runtime         = "python3.11"
  timeout         = 30
  memory_size     = 256
  
  environment {
    variables = {
      S3_BUCKET                = var.s3_bucket_name
      DYNAMODB_TABLE          = aws_dynamodb_table.api_keys.name
      REQUEST_LOGS_TABLE      = aws_dynamodb_table.request_logs.name
      URL_EXPIRY_SECONDS      = "3600"
      RATE_LIMIT_REQUESTS     = "100"
      RATE_LIMIT_WINDOW_SECONDS = "3600"
    }
  }
  
  depends_on = [
    aws_iam_role_policy.lambda_policy
  ]
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "api" {
  name        = "geoip-auth-api"
  description = "GeoIP Authentication API"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Gateway resource
resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "auth"
}

# API Gateway method - POST
resource "aws_api_gateway_method" "auth_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.auth.id
  http_method   = "POST"
  authorization = "NONE"
}

# API Gateway method - OPTIONS (for CORS)
resource "aws_api_gateway_method" "auth_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.auth.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# API Gateway integration - POST
resource "aws_api_gateway_integration" "auth_post" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.auth.id
  http_method = aws_api_gateway_method.auth_post.http_method
  
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.auth.invoke_arn
}

# API Gateway integration - OPTIONS
resource "aws_api_gateway_integration" "auth_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.auth.id
  http_method = aws_api_gateway_method.auth_options.http_method
  
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.auth.invoke_arn
}

# API Gateway deployment
resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.auth,
      aws_api_gateway_method.auth_post,
      aws_api_gateway_method.auth_options,
      aws_api_gateway_integration.auth_post,
      aws_api_gateway_integration.auth_options
    ]))
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway stage
resource "aws_api_gateway_stage" "api" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "v1"
  
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

# CloudWatch log group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/geoip-auth"
  retention_in_days = 7
}

# CloudWatch log group for Lambda
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/geoip-auth"
  retention_in_days = 7
}

# DynamoDB table for request logs (separate from API keys)
resource "aws_dynamodb_table" "request_logs" {
  name           = "geoip-request-logs"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "api_key_hash"
  range_key      = "request_time"
  
  attribute {
    name = "api_key_hash"
    type = "S"
  }
  
  attribute {
    name = "request_time"
    type = "N"
  }
  
  # TTL to automatically delete old logs after 30 days
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  
  tags = {
    Name        = "geoip-request-logs"
    Environment = var.environment
  }
}

# Outputs
output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = "${aws_api_gateway_stage.api.invoke_url}/auth"
}

output "dynamodb_table" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.api_keys.name
}

output "request_logs_table" {
  description = "DynamoDB request logs table name"
  value       = aws_dynamodb_table.request_logs.name
}

output "lambda_function" {
  description = "Lambda function name"
  value       = aws_lambda_function.auth.function_name
}