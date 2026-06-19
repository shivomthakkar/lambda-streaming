data "aws_iam_role" "execution" {
  name = var.role_name
}

data "aws_ecr_repository" "service" {
  name = var.ecr_repository_name
}

locals {
  name_prefix      = "${var.project_name}-${var.environment}"
  lambda_name      = local.name_prefix
  api_name         = "${local.name_prefix}-api"
  stage_name       = var.environment
  is_private       = var.endpoint_configuration == "PRIVATE"
  has_authorizer   = var.authorizer_arn != ""
  route_target_arn = "arn:aws:apigateway:${var.aws_region}:lambda:path/2021-11-15/functions/${aws_lambda_function.app.arn}/response-streaming-invocations"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = local.name_prefix
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_lambda_function" "app" {
  function_name = local.lambda_name
  role          = data.aws_iam_role.execution.arn
  package_type  = "Image"
  image_uri     = var.lambda_image_uri

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout_seconds

  tracing_config {
    mode = var.xray_tracing ? "Active" : "PassThrough"
  }

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = var.vpc_security_group_ids
  }

  environment {
    variables = {
      LOG_LEVEL              = var.log_level
      REMOTE_ENV_S3_URI      = var.remote_env
      APP_FUNCTION           = var.app_function
      ENDPOINT_CONFIGURATION = var.endpoint_configuration
      AWS_LWA_INVOKE_MODE    = "response_stream"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = local.common_tags
}

resource "aws_api_gateway_rest_api" "this" {
  name = local.api_name

  # REST APIs require an attached resource policy for access control.
  # Applies to both PRIVATE and REGIONAL endpoints.
  policy = var.api_gateway_policy_path != "" ? file(var.api_gateway_policy_path) : null

  dynamic "endpoint_configuration" {
    for_each = local.is_private ? [1] : []
    content {
      types            = ["PRIVATE"]
      vpc_endpoint_ids = [var.vpc_endpoint_id]
    }
  }

  dynamic "endpoint_configuration" {
    for_each = local.is_private ? [] : [1]
    content {
      types = ["REGIONAL"]
    }
  }

  tags = local.common_tags
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "root_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_rest_api.this.root_resource_id
  http_method   = "ANY"
  authorization = local.has_authorizer ? "CUSTOM" : "NONE"
  authorizer_id = local.has_authorizer ? aws_api_gateway_authorizer.this[0].id : null
}

resource "aws_api_gateway_method" "proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = local.has_authorizer ? "CUSTOM" : "NONE"
  authorizer_id = local.has_authorizer ? aws_api_gateway_authorizer.this[0].id : null
}

resource "aws_api_gateway_integration" "root_any" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_rest_api.this.root_resource_id
  http_method             = aws_api_gateway_method.root_any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.route_target_arn
  response_transfer_mode  = "STREAM"
  credentials             = data.aws_iam_role.execution.arn
}

resource "aws_api_gateway_integration" "proxy_any" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.route_target_arn
  response_transfer_mode  = "STREAM"
  credentials             = data.aws_iam_role.execution.arn
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_api_gateway_authorizer" "this" {
  count = local.has_authorizer ? 1 : 0

  name                             = "${local.name_prefix}-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  authorizer_uri                   = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${var.authorizer_arn}/invocations"
  type                             = "TOKEN"
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = var.authorizer_ttl_seconds
}

resource "aws_lambda_permission" "authorizer_invoke" {
  count = local.has_authorizer ? 1 : 0

  statement_id  = "AllowApiGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/*"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.root_any.id,
      aws_api_gateway_method.proxy_any.id,
      aws_api_gateway_integration.root_any.id,
      aws_api_gateway_integration.proxy_any.id,
      local.has_authorizer
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.root_any,
    aws_api_gateway_integration.proxy_any
  ]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = local.stage_name

  xray_tracing_enabled = var.xray_tracing

  tags = local.common_tags
}
