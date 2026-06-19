variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "project_name" {
  description = "Project/service logical name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "role_name" {
  description = "Existing IAM role name used by Lambda execution"
  type        = string
}

variable "lambda_image_uri" {
  description = "Fully-qualified Lambda image URI, usually pinned with Git SHA"
  type        = string
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB"
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 300
}

variable "log_level" {
  description = "Application log level"
  type        = string
  default     = "INFO"
}

variable "xray_tracing" {
  description = "Enable X-Ray active tracing"
  type        = bool
  default     = true
}

variable "remote_env" {
  description = "S3 URI for environment json loaded at runtime"
  type        = string
  default     = ""
}

variable "app_function" {
  description = "WSGI app entrypoint for gunicorn in module:object form"
  type        = string
  default     = "run:app"
}

variable "ecr_repository_name" {
  description = "Existing ECR repository name"
  type        = string
}

variable "endpoint_configuration" {
  description = "API endpoint type"
  type        = string

  validation {
    condition     = contains(["PRIVATE", "REGIONAL"], var.endpoint_configuration)
    error_message = "endpoint_configuration must be PRIVATE or REGIONAL"
  }
}

variable "vpc_subnet_ids" {
  description = "Lambda VPC subnet IDs"
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Lambda VPC security group IDs"
  type        = list(string)
}

variable "vpc_endpoint_id" {
  description = "Existing execute-api VPC endpoint ID, required for PRIVATE"
  type        = string
  default     = ""

  validation {
    condition     = var.endpoint_configuration != "PRIVATE" || length(trimspace(var.vpc_endpoint_id)) > 0
    error_message = "vpc_endpoint_id must be provided when endpoint_configuration is PRIVATE"
  }
}

variable "authorizer_arn" {
  description = "Existing Lambda authorizer ARN. Empty means no authorizer"
  type        = string
  default     = ""
}

variable "authorizer_ttl_seconds" {
  description = "Authorizer result cache TTL"
  type        = number
  default     = 300
}

variable "api_gateway_policy_path" {
  description = "Full path to API Gateway resource policy file"
  type        = string
  default     = ""
}
