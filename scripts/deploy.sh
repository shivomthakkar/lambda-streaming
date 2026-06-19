#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

ENVIRONMENT=""
CONFIG_PATH="${ROOT_DIR}/deployment_config.json"

usage() {
  cat <<EOF
Usage: $0 --env <stage_name1|stage_name2> [--config <local-path-or-s3-uri>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${ENVIRONMENT}" ]]; then
  usage
  exit 1
fi

if [[ "${CONFIG_PATH}" =~ ^s3:// ]]; then
  TMP_CONFIG="/tmp/streaming-service-deployment-config.json"
  aws s3 cp "${CONFIG_PATH}" "${TMP_CONFIG}"
  CONFIG_PATH="${TMP_CONFIG}"
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Config file not found: ${CONFIG_PATH}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws cli is required" >&2
  exit 1
fi

STATE_BUCKET="$(jq -r '.terraform_state.bucket' "${CONFIG_PATH}")"
STATE_REGION="$(jq -r '.terraform_state.region' "${CONFIG_PATH}")"
AWS_REGION="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].aws_region' "${CONFIG_PATH}")"
PROJECT_NAME="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].project_name' "${CONFIG_PATH}")"
ROLE_NAME="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].role_name' "${CONFIG_PATH}")"
ECR_REPO_NAME="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].ecr_repository_name' "${CONFIG_PATH}")"
REMOTE_ENV="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].remote_env // ""' "${CONFIG_PATH}")"
APP_FUNCTION="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].app_function' "${CONFIG_PATH}")"
LOG_LEVEL="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].log_level' "${CONFIG_PATH}")"
XRAY_TRACING="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].xray_tracing' "${CONFIG_PATH}")"
API_POLICY_PATH="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].apigateway_policy // ""' "${CONFIG_PATH}")"
ENDPOINT_CONFIGURATION="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].endpoint_configuration' "${CONFIG_PATH}")"
VPC_ENDPOINT_ID="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].vpc_config.vpc_endpoint_id // ""' "${CONFIG_PATH}")"
LAMBDA_MEMORY_SIZE="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].lambda_memory_size' "${CONFIG_PATH}")"
LAMBDA_TIMEOUT_SECONDS="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].lambda_timeout_seconds' "${CONFIG_PATH}")"
AUTHORIZER_ARN="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].authorizer.arn // ""' "${CONFIG_PATH}")"
AUTHORIZER_TTL="$(jq -r --arg e "${ENVIRONMENT}" '.[$e].authorizer.result_ttl // 300' "${CONFIG_PATH}")"

if [[ "${STATE_BUCKET}" == "null" || "${STATE_REGION}" == "null" ]]; then
  echo "terraform_state.bucket and terraform_state.region are required" >&2
  exit 1
fi

if [[ "${AWS_REGION}" == "null" || "${PROJECT_NAME}" == "null" || "${ROLE_NAME}" == "null" || "${ECR_REPO_NAME}" == "null" ]]; then
  echo "aws_region, project_name, role_name, and ecr_repository_name are required for ${ENVIRONMENT}" >&2
  exit 1
fi

if [[ "${ENDPOINT_CONFIGURATION}" == "PRIVATE" && -z "${VPC_ENDPOINT_ID}" ]]; then
  echo "vpc_config.vpc_endpoint_id is required when endpoint_configuration is PRIVATE" >&2
  exit 1
fi

SUBNETS=($(jq -r --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SubnetIds[]' "${CONFIG_PATH}"))
SGS=($(jq -r --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SecurityGroupIds[]' "${CONFIG_PATH}"))

if [[ ${#SUBNETS[@]} -eq 0 || ${#SGS[@]} -eq 0 ]]; then
  echo "At least one subnet and one security group are required" >&2
  exit 1
fi

pushd "${ROOT_DIR}" >/dev/null

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || cat Dockerfile requirements.txt $(find app -name '*.py' | sort) 2>/dev/null | shasum -a 256 | cut -c1-8)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
IMAGE_URI="${REPO_URI}:${GIT_SHA}"

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "${IMAGE_URI}" .
docker push "${IMAGE_URI}"

popd >/dev/null

STATE_KEY="${PROJECT_NAME}/${ENVIRONMENT}/terraform.tfstate"
terraform -chdir="${TF_DIR}" init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="key=${STATE_KEY}"

TF_ARGS=(
  -var "environment=${ENVIRONMENT}"
  -var "project_name=${PROJECT_NAME}"
  -var "aws_region=${AWS_REGION}"
  -var "role_name=${ROLE_NAME}"
  -var "lambda_image_uri=${IMAGE_URI}"
  -var "lambda_memory_size=${LAMBDA_MEMORY_SIZE}"
  -var "lambda_timeout_seconds=${LAMBDA_TIMEOUT_SECONDS}"
  -var "log_level=${LOG_LEVEL}"
  -var "xray_tracing=${XRAY_TRACING}"
  -var "remote_env=${REMOTE_ENV}"
  -var "app_function=${APP_FUNCTION}"
  -var "ecr_repository_name=${ECR_REPO_NAME}"
  -var "endpoint_configuration=${ENDPOINT_CONFIGURATION}"
  -var "vpc_endpoint_id=${VPC_ENDPOINT_ID}"
  -var "authorizer_arn=${AUTHORIZER_ARN}"
  -var "authorizer_ttl_seconds=${AUTHORIZER_TTL}"
  -var "api_gateway_policy_path=${API_POLICY_PATH}"
  -var "vpc_subnet_ids=$(jq -c --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SubnetIds' "${CONFIG_PATH}")"
  -var "vpc_security_group_ids=$(jq -c --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SecurityGroupIds' "${CONFIG_PATH}")"
)

terraform -chdir="${TF_DIR}" validate
terraform -chdir="${TF_DIR}" apply -auto-approve "${TF_ARGS[@]}"

LAMBDA_FUNCTION_NAME="$(terraform -chdir="${TF_DIR}" output -raw lambda_function_name)"
aws lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null

echo "Deployment complete for ${ENVIRONMENT}."
