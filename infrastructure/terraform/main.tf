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

variable "api_keys" {
  description = "Comma-separated list of allowed API keys"
  type        = string
  sensitive   = true
  default     = ""  # Set this via terraform.tfvars or environment variable
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
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*"
        ]
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "auth_lambda" {
  filename         = "lambda_deployment.zip"
  function_name    = "geoip-auth"
  role            = aws_iam_role.lambda_role.arn
  handler         = "auth_handler.lambda_handler"
  source_code_hash = filebase64sha256("lambda_deployment.zip")
  runtime         = "python3.11"
  timeout         = 30
  memory_size     = 256
  
  environment {
    variables = {
      S3_BUCKET          = var.s3_bucket_name
      ALLOWED_API_KEYS   = var.api_keys
      URL_EXPIRY_SECONDS = "3600"
    }
  }
  
  tags = {
    Name        = "geoip-auth"
    Environment = var.environment
  }
}

# API Gateway
resource "aws_apigatewayv2_api" "api" {
  name          = "geoip-auth-api"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins     = ["*"]
    allow_methods     = ["POST", "OPTIONS"]
    allow_headers     = ["Content-Type", "X-API-Key"]
    max_age          = 300
  }
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# API Gateway integration
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.auth_lambda.invoke_arn
}

# API Gateway route for POST
resource "aws_apigatewayv2_route" "auth_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# API Gateway route for OPTIONS (CORS)
resource "aws_apigatewayv2_route" "options_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "OPTIONS /auth"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# API Gateway stage
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "v1"
  auto_deploy = true
  
  default_route_settings {
    throttle_rate_limit  = 100
    throttle_burst_limit = 50
  }
}

# Outputs
output "api_gateway_url" {
  description = "API Gateway URL for authentication"
  value       = "${aws_apigatewayv2_stage.api_stage.invoke_url}/auth"
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.auth_lambda.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.auth_lambda.arn
}

output "setup_instructions" {
  description = "Instructions for setting up API keys"
  value = <<-EOT
    
    ============================================
    SETUP INSTRUCTIONS:
    ============================================
    
    1. Set your API keys in terraform.tfvars:
       api_keys = "your-key-1,your-key-2,your-key-3"
    
    2. Or set via environment variable:
       export TF_VAR_api_keys="your-key-1,your-key-2,your-key-3"
    
    3. Deploy:
       terraform apply
    
    4. Update API keys anytime by changing the variable and running:
       terraform apply -var="api_keys=new-key-1,new-key-2"
    
    5. API Endpoint: ${aws_apigatewayv2_stage.api_stage.invoke_url}/auth
    
    ============================================
  EOT
}