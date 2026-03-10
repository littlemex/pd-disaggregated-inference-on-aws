#!/bin/bash
##
## SSM Helper Functions for NIXL Deployment
##
## Provides utilities for:
## - Running commands via SSM send-command
## - Waiting for command completion
## - S3 file transfer coordination
##

set -eo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

##
## ssm_run_command: Run a command via SSM and return command ID
##
## Usage:
##   COMMAND_ID=$(ssm_run_command <instance-id> <region> <command>)
##
ssm_run_command() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local COMMAND="$3"

    log "Running SSM command on ${INSTANCE_ID}..."

    # Debug: Show command being sent
    echo "[DEBUG] Command to be executed:" >&2
    echo "$COMMAND" >&2
    echo "" >&2

    # Properly escape command for JSON using jq
    local COMMAND_JSON=$(jq -n --arg cmd "$COMMAND" '{"commands": [$cmd]}')

    local COMMAND_ID=$(aws ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters "$COMMAND_JSON" \
        --region "${REGION}" \
        --output text \
        --query "Command.CommandId" 2>&1)

    if [ $? -ne 0 ]; then
        error "Failed to send SSM command: ${COMMAND_ID}"
    fi

    echo "${COMMAND_ID}"
}

##
## ssm_run_commands: Run multiple commands via SSM (as array)
##
## Usage:
##   COMMAND_ID=$(ssm_run_commands <instance-id> <region> <command1> <command2> ...)
##
ssm_run_commands() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    shift 2
    local COMMANDS=("$@")

    log "Running SSM commands on ${INSTANCE_ID}..."

    # Build JSON array using jq
    local COMMANDS_JSON=$(jq -n --args '{"commands": $ARGS.positional}' -- "${COMMANDS[@]}")

    local COMMAND_ID=$(aws ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters "$COMMANDS_JSON" \
        --region "${REGION}" \
        --output text \
        --query "Command.CommandId" 2>&1)

    if [ $? -ne 0 ]; then
        error "Failed to send SSM command: ${COMMAND_ID}"
    fi

    echo "${COMMAND_ID}"
}

##
## ssm_wait_command: Wait for SSM command to complete
##
## Usage:
##   ssm_wait_command <command-id> <instance-id> <region> [timeout-seconds]
##
ssm_wait_command() {
    local COMMAND_ID="$1"
    local INSTANCE_ID="$2"
    local REGION="$3"
    local TIMEOUT="${4:-300}"  # Default 5 minutes

    save_last_command "$COMMAND_ID" "$INSTANCE_ID" "$REGION"

    log "Waiting for command ${COMMAND_ID} to complete (timeout: ${TIMEOUT}s)..."

    local ELAPSED=0
    local INTERVAL=5

    while [ $ELAPSED -lt $TIMEOUT ]; do
        local STATUS=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}" \
            --query "Status" \
            --output text 2>/dev/null || echo "Pending")

        case "$STATUS" in
            "Success")
                success "Command completed successfully"
                return 0
                ;;
            "Failed"|"Cancelled"|"TimedOut")
                # Get output for debugging
                local OUTPUT=$(aws ssm get-command-invocation \
                    --command-id "${COMMAND_ID}" \
                    --instance-id "${INSTANCE_ID}" \
                    --region "${REGION}" \
                    --query "StandardErrorContent" \
                    --output text 2>/dev/null || echo "No output")
                error "Command failed with status: ${STATUS}\nError: ${OUTPUT}"
                ;;
            "InProgress"|"Pending")
                echo -n "."
                sleep $INTERVAL
                ELAPSED=$((ELAPSED + INTERVAL))
                ;;
            *)
                echo -n "?"
                sleep $INTERVAL
                ELAPSED=$((ELAPSED + INTERVAL))
                ;;
        esac
    done

    error "Command timed out after ${TIMEOUT} seconds"
}

##
## ssm_run_and_wait: Run SSM command and wait for completion
##
## Usage:
##   ssm_run_and_wait <instance-id> <region> <command> [timeout]
##
ssm_run_and_wait() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local COMMAND="$3"
    local TIMEOUT="${4:-300}"

    local COMMAND_ID=$(ssm_run_command "${INSTANCE_ID}" "${REGION}" "${COMMAND}")
    ssm_wait_command "${COMMAND_ID}" "${INSTANCE_ID}" "${REGION}" "${TIMEOUT}"
}

##
## ssm_get_output: Get command output
##
## Usage:
##   OUTPUT=$(ssm_get_output <command-id> <instance-id> <region>)
##
ssm_get_output() {
    local COMMAND_ID="$1"
    local INSTANCE_ID="$2"
    local REGION="$3"

    aws ssm get-command-invocation \
        --command-id "${COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --region "${REGION}" \
        --query "StandardOutputContent" \
        --output text
}

##
## s3_upload_file: Upload file to S3
##
## Usage:
##   s3_upload_file <local-file> <s3-bucket> <s3-key> <region>
##
s3_upload_file() {
    local LOCAL_FILE="$1"
    local S3_BUCKET="$2"
    local S3_KEY="$3"
    local REGION="$4"

    if [ ! -f "${LOCAL_FILE}" ]; then
        error "Local file not found: ${LOCAL_FILE}"
    fi

    log "Uploading ${LOCAL_FILE} to s3://${S3_BUCKET}/${S3_KEY}..."

    aws s3 cp "${LOCAL_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --region "${REGION}"

    if [ $? -eq 0 ]; then
        success "File uploaded successfully"
    else
        error "S3 upload failed"
    fi
}

##
## ssm_download_from_s3: Download file from S3 via SSM
##
## Usage:
##   ssm_download_from_s3 <instance-id> <region> <s3-bucket> <s3-key> <remote-path>
##
ssm_download_from_s3() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local S3_KEY="$4"
    local REMOTE_PATH="$5"

    local COMMAND="aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ${REMOTE_PATH} --region ${REGION}"

    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${COMMAND}" 60
}

##
## ssm_run_script: Run a shell script via S3 distribution
##
## Usage:
##   ssm_run_script <instance-id> <region> <s3-bucket> <local-script> [timeout]
##
## This function:
##   1. Validates script syntax locally
##   2. Uploads script to S3
##   3. Downloads and executes on remote instance via SSM
##   4. Cleans up remote script file
##
ssm_run_script() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local LOCAL_SCRIPT="$4"
    local TIMEOUT="${5:-300}"

    if [ ! -f "${LOCAL_SCRIPT}" ]; then
        error "Script file not found: ${LOCAL_SCRIPT}"
    fi

    # Validate script syntax locally
    if ! bash -n "${LOCAL_SCRIPT}" 2>/dev/null; then
        error "Script syntax error in ${LOCAL_SCRIPT}"
    fi

    local SCRIPT_NAME=$(basename "${LOCAL_SCRIPT}")
    local S3_KEY="scripts/${SCRIPT_NAME}"
    local REMOTE_PATH="/tmp/${SCRIPT_NAME}"

    # Upload to S3
    log "Uploading script ${SCRIPT_NAME} to S3..."
    aws s3 cp "${LOCAL_SCRIPT}" "s3://${S3_BUCKET}/${S3_KEY}" \
        --region "${REGION}" --quiet || error "S3 upload failed"

    # Execute on remote instance
    local RUN_CMD="aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ${REMOTE_PATH} --region ${REGION} --quiet && chmod +x ${REMOTE_PATH} && bash ${REMOTE_PATH} && rm -f ${REMOTE_PATH}"

    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${RUN_CMD}" "${TIMEOUT}"
}

##
## ssm_run_script_with_env: Run a script template with environment variable substitution
##
## Usage:
##   ssm_run_script_with_env <instance-id> <region> <s3-bucket> <template-script> [timeout]
##
## This function uses envsubst to expand variables like ${VAR_NAME} in the script template.
## Make sure to export all required variables before calling this function.
##
ssm_run_script_with_env() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local TEMPLATE_SCRIPT="$4"
    local TIMEOUT="${5:-300}"

    if [ ! -f "${TEMPLATE_SCRIPT}" ]; then
        error "Template script not found: ${TEMPLATE_SCRIPT}"
    fi

    # Create temporary expanded script
    local TEMP_SCRIPT=$(mktemp /tmp/expanded-XXXXXX.sh)

    # Expand environment variables
    envsubst < "${TEMPLATE_SCRIPT}" > "${TEMP_SCRIPT}"

    # Validate expanded script
    if ! bash -n "${TEMP_SCRIPT}" 2>/dev/null; then
        cat "${TEMP_SCRIPT}" >&2
        rm -f "${TEMP_SCRIPT}"
        error "Expanded script has syntax errors"
    fi

    # Run the expanded script
    ssm_run_script "${INSTANCE_ID}" "${REGION}" "${S3_BUCKET}" "${TEMP_SCRIPT}" "${TIMEOUT}"

    # Cleanup
    rm -f "${TEMP_SCRIPT}"
}

##
## ssm_run_task: Run task_runner.sh remotely via S3 distribution
##
## Usage:
##   ssm_run_task <instance-id> <region> <s3-bucket> <task-json> <task-runner-script> [timeout]
##
## This function:
##   1. Uploads task_runner.sh and task JSON to S3
##   2. Downloads both on remote instance via SSM
##   3. Executes task_runner.sh with the JSON on remote
##   4. Cleans up remote files
##
ssm_run_task() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local TASK_JSON="$4"
    local TASK_RUNNER="$5"
    local CONFIG_FILE="$6"
    local TIMEOUT="${7:-600}"

    if [ ! -f "${TASK_JSON}" ]; then
        error "Task JSON not found: ${TASK_JSON}"
    fi
    if [ ! -f "${TASK_RUNNER}" ]; then
        error "Task runner not found: ${TASK_RUNNER}"
    fi
    if [ ! -f "${CONFIG_FILE}" ]; then
        error "Config file not found: ${CONFIG_FILE}"
    fi

    local JSON_NAME=$(basename "${TASK_JSON}")
    local RUNNER_NAME=$(basename "${TASK_RUNNER}")
    local CONFIG_NAME=$(basename "${CONFIG_FILE}")

    # Upload all files to S3
    log "Uploading task files to S3..."
    aws s3 cp "${TASK_RUNNER}" "s3://${S3_BUCKET}/scripts/${RUNNER_NAME}" \
        --region "${REGION}" --quiet || error "Failed to upload task runner"
    aws s3 cp "${TASK_JSON}" "s3://${S3_BUCKET}/scripts/tasks/${JSON_NAME}" \
        --region "${REGION}" --quiet || error "Failed to upload task JSON"
    aws s3 cp "${CONFIG_FILE}" "s3://${S3_BUCKET}/scripts/${CONFIG_NAME}" \
        --region "${REGION}" --quiet || error "Failed to upload config"

    local REMOTE_DIR="/tmp/task-runner-$$"

    local RUN_CMD="set -e
mkdir -p ${REMOTE_DIR}
aws s3 cp s3://${S3_BUCKET}/scripts/${RUNNER_NAME} ${REMOTE_DIR}/${RUNNER_NAME} --region '${REGION}' --quiet
aws s3 cp s3://${S3_BUCKET}/scripts/tasks/${JSON_NAME} ${REMOTE_DIR}/${JSON_NAME} --region '${REGION}' --quiet
aws s3 cp s3://${S3_BUCKET}/scripts/${CONFIG_NAME} ${REMOTE_DIR}/${CONFIG_NAME} --region '${REGION}' --quiet
set -a
source ${REMOTE_DIR}/${CONFIG_NAME}
set +a
chmod +x ${REMOTE_DIR}/${RUNNER_NAME}
bash ${REMOTE_DIR}/${RUNNER_NAME} ${REMOTE_DIR}/${JSON_NAME}
rm -rf ${REMOTE_DIR}"

    log "Running task '${JSON_NAME}' on ${INSTANCE_ID}..."
    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${RUN_CMD}" "${TIMEOUT}"
}

##
## ssm_run_script_with_param: Run script with Parameter Store path injected
##
## Usage:
##   ssm_run_script_with_param <instance-id> <region> <s3-bucket> <script> <param-name> [timeout]
##
ssm_run_script_with_param() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local LOCAL_SCRIPT="$4"
    local PARAM_NAME="$5"
    local TIMEOUT="${6:-600}"

    if [ ! -f "${LOCAL_SCRIPT}" ]; then
        error "Script not found: ${LOCAL_SCRIPT}"
    fi

    if ! bash -n "${LOCAL_SCRIPT}" 2>/dev/null; then
        error "Script syntax error: ${LOCAL_SCRIPT}"
    fi

    local SCRIPT_NAME=$(basename "${LOCAL_SCRIPT}")
    local S3_KEY="scripts/${SCRIPT_NAME}"
    local REMOTE_PATH="/tmp/${SCRIPT_NAME}"

    log "Uploading ${SCRIPT_NAME} to S3..."
    aws s3 cp "${LOCAL_SCRIPT}" "s3://${S3_BUCKET}/${S3_KEY}" \
        --region "${REGION}" --quiet || error "S3 upload failed"

    local RUN_CMD="export HOME=/root && export PARAM_NAME='${PARAM_NAME}' && export AWS_REGION='${REGION}' && aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ${REMOTE_PATH} --region ${REGION} --quiet && chmod +x ${REMOTE_PATH} && bash ${REMOTE_PATH} && rm -f ${REMOTE_PATH}"

    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${RUN_CMD}" "${TIMEOUT}"
}

LAST_COMMAND_FILE="/tmp/ssm-last-command.json"

# Save last command info
save_last_command() {
    local COMMAND_ID="$1"
    local INSTANCE_ID="$2"
    local REGION="$3"
    jq -n --arg cid "$COMMAND_ID" --arg iid "$INSTANCE_ID" --arg r "$REGION" \
        '{command_id: $cid, instance_id: $iid, region: $r}' > "$LAST_COMMAND_FILE"
}

export -f log success warning error
export -f ssm_run_command ssm_run_commands ssm_wait_command ssm_run_and_wait ssm_get_output
export -f s3_upload_file ssm_download_from_s3
export -f ssm_run_script ssm_run_script_with_env
export -f ssm_run_task
export -f ssm_run_script_with_param
export -f save_last_command