#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

ENVIRONMENT=""
CONFIG_PATH="${ROOT_DIR}/deployment_config.json"
CONFIRM="false"

usage() {
  cat <<EOF
Usage: $0 --env <stage_name1|stage_name2> [--config <local-path-or-s3-uri>] [--confirm]
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
    --confirm)
      CONFIRM="true"
      shift
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

if [[ "${CONFIRM}" != "true" ]]; then
  read -r -p "Destroy resources for ${ENVIRONMENT}? Type yes to continue: " answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
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

SUBNETS=($(jq -r --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SubnetIds[]' "${CONFIG_PATH}"))
SGS=($(jq -r --arg e "${ENVIRONMENT}" '.[$e].vpc_config.SecurityGroupIds[]' "${CONFIG_PATH}"))

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
  -var "lambda_image_uri=placeholder"
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

terraform -chdir="${TF_DIR}" destroy -auto-approve "${TF_ARGS[@]}"

echo "Destroy complete for ${ENVIRONMENT}."
