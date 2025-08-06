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

# ============================================
# Custom Domain Configuration
# ============================================

# Variables for custom domain
variable "custom_domain_name" {
  description = "Custom domain name for the API"
  type        = string
  default     = "geoip.ytrack.io"
}

variable "acm_certificate_arn" {
  description = "ARN of existing ACM certificate for the domain (must be in us-east-1)"
  type        = string
  default     = "arn:aws:acm:us-east-1:562693942294:certificate/ca3f2422-060b-4723-abde-caf081335120"
}

# CloudFront distribution for custom domain
resource "aws_cloudfront_distribution" "api_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "GeoIP API Distribution"
  price_class         = "PriceClass_100"  # North America and Europe
  
  aliases = [var.custom_domain_name]
  
  # Origin pointing to API Gateway
  origin {
    domain_name = replace(aws_apigatewayv2_stage.api_stage.invoke_url, "https://", "")
    origin_id   = "api-gateway-origin"
    origin_path = ""
    
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  
  # Default cache behavior
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "api-gateway-origin"
    
    forwarded_values {
      query_string = true
      headers      = ["X-API-Key", "Content-Type", "Authorization"]
      
      cookies {
        forward = "none"
      }
    }
    
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    compress               = true
  }
  
  # Specific behavior for /auth endpoint
  ordered_cache_behavior {
    path_pattern     = "/auth*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "api-gateway-origin"
    
    forwarded_values {
      query_string = true
      headers      = ["*"]  # Forward all headers for API requests
      
      cookies {
        forward = "all"
      }
    }
    
    viewer_protocol_policy = "https-only"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }
  
  # SSL certificate configuration
  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  
  tags = {
    Name        = "geoip-api-distribution"
    Environment = var.environment
  }
}

# Additional outputs for CloudFront
output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.api_distribution.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name (for DNS CNAME)"
  value       = aws_cloudfront_distribution.api_distribution.domain_name
}

output "custom_domain_url" {
  description = "Custom domain URL for the API"
  value       = "https://${var.custom_domain_name}/auth"
}

output "cloudflare_dns_instructions" {
  description = "Instructions for Cloudflare DNS configuration"
  value = <<-EOT
    
    ============================================
    CLOUDFLARE DNS CONFIGURATION:
    ============================================
    
    Add the following DNS record in Cloudflare:
    
    Type:   CNAME
    Name:   geoip
    Target: ${aws_cloudfront_distribution.api_distribution.domain_name}
    Proxy:  DNS only (gray cloud) - IMPORTANT!
    
    The proxy MUST be disabled (gray cloud) for CloudFront to work.
    
    ============================================
  EOT
}