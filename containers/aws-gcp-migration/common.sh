#!/bin/bash
#
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

ERR_GENERIC=1
ERR_COMMAND_NOT_AVAILABLE=2
ERR_LIBRARY_NOT_AVAILABLE=3
ERR_ARGUMENT_EVAL=4

AWS_TO_GCP_DEMO_DIRECTORY_PATH="${REPOSITORY_ROOT_DIRECTORY_PATH}/containers/aws-gcp-migration"
AWS_TO_GCP_DEMO_TERRAFORM_DIRECTORY_PATH="${AWS_TO_GCP_DEMO_DIRECTORY_PATH}/gcp/terraform"

ACCELERATED_PLATFORMS_REPOSITORY_PATH="${AWS_TO_GCP_DEMO_DIRECTORY_PATH}/gcp/accelerated-platforms"
export ACP_REPO_DIR="${ACCELERATED_PLATFORMS_REPOSITORY_PATH}"
export ACP_PLATFORM_BASE_DIR="${ACCELERATED_PLATFORMS_REPOSITORY_PATH}/platforms/gke/base"
export ACP_PLATFORM_CORE_DIR="${ACP_PLATFORM_BASE_DIR}/core"
ACP_PLATFORM_SHARED_CONFIG_DIR="${ACP_PLATFORM_BASE_DIR}/_shared_config"
ACP_PLATFORM_CONTAINER_NODE_POOL_DIR="${ACP_PLATFORM_CORE_DIR}/container_node_pool"

TERRAFORM_GCS_BACKEND_FILE_NAME="backend.gcs.tfbackend"

DMS_USER_PASSWORD_SOURCE_DATABASE_FILE_PATH="${AWS_TO_GCP_DEMO_DIRECTORY_PATH}/dms-user-password-source-database.txt"

if [ ! -e "${DMS_USER_PASSWORD_SOURCE_DATABASE_FILE_PATH}" ]; then
  echo "Cannot find the file where the Database Migration Service user password is stored: ${DMS_USER_PASSWORD_SOURCE_DATABASE_FILE_PATH}. Create the file and save the password in the file."
  exit "${ERR_ARGUMENT_EVAL}"
fi

SOURCE_DATABASE_DMS_PASSWORD="$(cat "${DMS_USER_PASSWORD_SOURCE_DATABASE_FILE_PATH}")"

# Terraform runtime variables
export TF_IN_AUTOMATION="1"
export TF_VAR_cluster_project_id="${GOOGLE_CLOUD_PROJECT_ID}"
export TF_VAR_platform_name="a-g-demo"
export TF_VAR_terraform_project_id="${TF_VAR_cluster_project_id}"
export TF_VAR_source_database_password="${SOURCE_DATABASE_DMS_PASSWORD}"
export TF_VAR_source_database_host="${SOURCE_DATABASE_HOSTNAME}"
export TF_VAR_source_database_username="${SOURCE_DATABASE_DMS_USERNAME}"

is_command_available() {
  if command -v "${1}" >/dev/null 2>&1; then
    return 0
  else
    return "${ERR_COMMAND_NOT_AVAILABLE}"
  fi
}

apply_or_destroy_terraservice() {
  local terraservice
  terraservice="${1}"

  local operation_mode
  operation_mode="${2:-"not set"}"

  echo "Initializing ${terraservice} Terraform environment"
  cd "${AWS_TO_GCP_DEMO_TERRAFORM_DIRECTORY_PATH}/${terraservice}" &&
    terraform init -backend-config="${TERRAFORM_GCS_BACKEND_FILE_NAME}" -input=false

  echo "Current working directory: $(pwd)"

  if [[ "${operation_mode}" == "apply" ]]; then
    echo "Provisioning ${terraservice}"
    terraform plan -input=false -out=tfplan &&
      terraform apply -input=false tfplan
    _terraform_result=$?
  elif [[ "${operation_mode}" == "destroy" ]]; then
    echo "Destroying ${terraservice}"
    terraform destroy \
      -auto-approve \
      -input=false
    _terraform_result=$?
  else
    echo "Error: operation mode not supported: ${operation_mode}"
    _terraform_result=${ERR_ARGUMENT_EVAL}
  fi

  rm -rf \
    "${AWS_TO_GCP_DEMO_TERRAFORM_DIRECTORY_PATH}/${terraservice}/.terraform" \
    "${AWS_TO_GCP_DEMO_TERRAFORM_DIRECTORY_PATH}/${terraservice}/tfplan"

  if [[ ${_terraform_result} -ne 0 ]]; then
    echo "Terraform ${operation_mode} command failed with code ${_terraform_result} for ${terraservice}"
    exit ${_terraform_result}
  fi
}

provision_terraservice() {
  apply_or_destroy_terraservice "${1}" "apply"
}

destroy_terraservice() {
  apply_or_destroy_terraservice "${1}" "destroy"
}

if ! is_command_available git; then
  echo "Git is not available on the host. Install it and run this script again"
  exit "${ERR_COMMAND_NOT_AVAILABLE}"
fi

if ! is_command_available terraform; then
  echo "Terraform is not available on the host. Install it and run this script again"
  exit "${ERR_COMMAND_NOT_AVAILABLE}"
fi

core_platform_terraservices=(
  "initialize"
  "networking"
  "container_cluster"
  "container_node_pool"
)

aws_to_gcp_migration_demo_terraservices=(
  container_image_repository
  cloud_sql
)

core_platform_configuration_files=(
  cluster_variables.tf
  cluster.auto.tfvars
  platform_variables.tf
  platform.auto.tfvars
)
