# LambdaStreaming

LambdaStreaming is a FastAPI-based streaming service packaged for AWS Lambda (container image) and deployed with Terraform. It demonstrates Server-Sent Events (SSE) from a Lambda runtime through API Gateway streaming integrations.

## Architecture

- FastAPI app serving:
  - `GET /` demo UI
  - `GET /stream` SSE stream with chunked events
  - `GET /hello-world-stream` simple SSE example
- AWS Lambda container runtime using AWS Lambda Web Adapter
- API Gateway REST API with Lambda proxy integrations configured for streaming
- Terraform-managed infrastructure (Lambda, API Gateway, stage, permissions, optional authorizer)

## Project Structure

```
LambdaStreaming
├── terraform
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf
│   └── outputs.tf
├── scripts
│   ├── deploy.sh
│   └── destroy.sh
├── app
│   ├── __init__.py
│   ├── routes.py
│   └── stream.py
├── templates
│   └── index.html
├── tests
│   └── test_stream.py
├── deployment.sample.json
├── Dockerfile
├── entrypoint.sh
├── requirements.txt
├── run.py
├── .gitignore
└── README.md
```

## Prerequisites

- Python 3.9
- Docker
- AWS CLI
- Terraform >= 1.5.0

## Local Development

1. Clone and enter the project:
   ```
   git clone <repository-url>
   cd LambdaStreaming
   ```

2. Create a virtual environment:
   ```
   python -m venv venv
   ```

3. Activate it:
   - Windows:
   ```
   venv\Scripts\activate
   ```
   - macOS/Linux:
   ```
   source venv/bin/activate
   ```

4. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

5. Run locally:
   ```
   python run.py
   ```

6. Open:
- `http://127.0.0.1:8080/`

7. Verify streaming from terminal:
```bash
curl -N http://127.0.0.1:8080/stream
```

## Container Image

Build and run Lambda-compatible image locally:

```bash
docker build --platform linux/amd64 -t lambda-streaming .
docker run --platform linux/amd64 --rm -p 8080:8080 lambda-streaming
```

## Deployment Configuration

- Copy `deployment.sample.json` to `deployment_config.json` and fill environment-specific values.
- `scripts/deploy.sh` and `scripts/destroy.sh` default to `deployment_config.json`.
- You can override config file path using `--config` with a local path or `s3://` URI.

Expected shape:

```json
{
   "terraform_state": {
      "bucket": "<s3-state-bucket>", // S3 bucket used for Terraform state
      "region": "<state-region>" // Region where the state bucket exists
   },
   "<env>": {
      "aws_region": "<aws-region>", // Deployment region for Lambda and API Gateway
      "project_name": "<service-name>", // Logical service name used in resource naming
      "role_name": "<existing-lambda-execution-role-name>", // Pre-existing IAM role for Lambda execution
      "ecr_repository_name": "<existing-ecr-repo>", // Pre-existing ECR repository name
      "app_function": "run:app",
      "log_level": "INFO",
      "xray_tracing": true,
      "remote_env": "", // Optional S3 URI to JSON env vars loaded at startup
      "apigateway_policy": "../api-gateway-policy.json", // API Gateway resource policy file path
      "endpoint_configuration": "PRIVATE", // PRIVATE or REGIONAL
      "vpc_config": {
         "SubnetIds": ["subnet-..."], // Lambda subnets
         "SecurityGroupIds": ["sg-..."], // Lambda security groups
         "vpc_endpoint_id": "vpce-..." // Required when endpoint_configuration is PRIVATE
      },
      "lambda_memory_size": 512,
      "lambda_timeout_seconds": 600,
      "authorizer": {
         "arn": "", // Leave empty string to disable custom Lambda authorizer
         "result_ttl": 300 // Authorizer cache TTL in seconds
      }
   }
}
```

Notes:
- `<env>` is your environment key in the deployment config (for example: `dev`, `test`, `staging`, `prod`).
- For `endpoint_configuration = PRIVATE`, `vpc_config.vpc_endpoint_id` is required.
- Set `authorizer.arn` to an empty string to disable custom authorizer.
- `role_name` and `ecr_repository_name` must reference existing AWS resources.
- `apigateway_policy` should point to a readable local file path from the Terraform module runtime.

Important config keys:
- `terraform_state.bucket`, `terraform_state.region`
- `<env>.aws_region`, `<env>.project_name`, `<env>.role_name`
- `<env>.ecr_repository_name`, `<env>.app_function`
- `<env>.endpoint_configuration` (`PRIVATE` or `REGIONAL`)
- `<env>.vpc_config.SubnetIds`, `<env>.vpc_config.SecurityGroupIds`
- `<env>.vpc_config.vpc_endpoint_id` (required for `PRIVATE`)
- `<env>.authorizer.arn` (optional)
- `<env>.apigateway_policy` (path to API Gateway policy JSON)

## Deploy and Destroy

Deploy:

```bash
./scripts/deploy.sh --env <environment_name>
```

Destroy:

```bash
./scripts/destroy.sh --env <environment_name> --confirm
```

With explicit config:

```bash
./scripts/deploy.sh --env <environment_name> --config ./deployment_config.json
./scripts/destroy.sh --env <environment_name> --config ./deployment_config.json --confirm
```

## Terraform Notes

- AWS provider version is pinned to `>= 6.25.0` for API Gateway response streaming support.
- API Gateway integrations use `response_transfer_mode = "STREAM"`.
- Integration URI uses Lambda response-streaming invocation path (`2021-11-15`).
- Lambda runtime sets `AWS_LWA_INVOKE_MODE=response_stream`.

## Testing

Run unit tests:

```
pytest tests/test_stream.py
```

## Pipeline

An Azure DevOps pipeline is available in `workflows/deploy-to-env.yml` for test-and-deploy automation.

## License

This project is licensed under the MIT License.