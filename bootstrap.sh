#!/bin/bash
set -euo pipefail

# Preflight script version control
# To update: visit https://github.com/PaloAltoNetworks/cc-permissions-preflight/commits/main
# and update PREFLIGHT_SCRIPT_VERSION below with the desired commit SHA or branch/tag
# Use "main" for latest version, or pin to a specific commit SHA for production stability
readonly PREFLIGHT_SCRIPT_BASE_URL="https://raw.githubusercontent.com/PaloAltoNetworks/cc-permissions-preflight"
readonly PREFLIGHT_SCRIPT_VERSION="d7c52a32b2421de7b50a95c19de5eaf653b34403"

# Args: <target_mg_id> <subscription_id> <preflight_enabled:true|false> <onboarding_type:tenant|mg>
# Note: target_mg_id is either tenant_id (for tenant-level) or management_group_id (for MG-level)
# Terraform validates that only one is provided before calling this script
readonly MG_ID="${1:-}"
readonly SUBSCRIPTION_ID="${2:-}"
readonly PREFLIGHT_ENABLED="${3:-true}"
readonly ONBOARDING_TYPE="${4:-mg}"

# Load parameters.sh and convert fields that are JSON-like to valid JSON strings
if [[ -f ./parameters.sh ]]; then
  # shellcheck disable=SC1091
  source ./parameters.sh 2>/dev/null || true
fi

# Strip ANSI color codes and control characters
strip_ansi() {
  local str="$1"
  # Remove ANSI escape sequences (colors, formatting, etc.)
  printf '%s' "$str" | sed -E 's/\x1b\[[0-9;]*[mGKHJh]//g; s/\x1b\([B0]//g; s/\x0d//g'
}

# Escape string for JSON output (handles quotes, newlines, backslashes, ANSI codes)
json_escape() {
  local str="$1"
  # First strip ANSI codes, then escape for JSON
  local clean
  clean=$(strip_ansi "$str")
  # Properly escape for JSON: backslash, quotes, tabs, and newlines
  printf '%s' "$clean" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"$(printf '\t')"'/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

# Convert shell-style JSON to proper JSON (single quotes to double quotes)
to_json_string() {
  local str="$1"
  json_escape "$(printf '%s' "$str" | sed "s/'/\"/g")"
}

# Pre-process JSON fields from parameters.sh
TAGS_JSON=$(to_json_string "${tags:-}")
TEMPLATE_VERSION_JSON=$(to_json_string "${template_version:-}")

# Initialize preflight result variables
PREFLIGHT_OK="false"
PREFLIGHT_ERROR=""
PREFLIGHT_OUTPUT=""

# Run preflight checks if enabled
run_preflight_checks() {
  local preflight_url="${PREFLIGHT_SCRIPT_BASE_URL}/${PREFLIGHT_SCRIPT_VERSION}/preflight_check.sh"
  local preflight_input
  
  # Check if audit logs are enabled by examining template_version
  # This applies to both tenant and management group onboarding
  local audit_enabled="n"
  if [[ -n "${template_version:-}" ]]; then
    # Parse template_version JSON to check for any key starting with AUDIT_LOGS
    # template_version is a JSON object like: {"BASE-arm_org_base":"1.0.0","AUDIT_LOGS-arm_organization_audit":"1.0.0"}
    if echo "${template_version}" | sed "s/'/\"/g" | grep -qE '"AUDIT_LOGS-[^"]+":'; then
      audit_enabled="y"
    fi
  fi
  
  # Build preflight input based on onboarding type
  if [[ "${ONBOARDING_TYPE}" == "tenant" ]]; then
    # Tenant-level: menu choice (5) + newline + audit logs flag
    preflight_input="5
${audit_enabled}"
  else
    # Management Group-level: menu choice (4) + newline + MG ID + newline + audit logs flag
    preflight_input="4
${MG_ID}
${audit_enabled}"
  fi
  
  # Run preflight script with process substitution
  local output exit_code
  output=$(echo -e "${preflight_input}" | bash <(curl -fsSL "${preflight_url}") 2>&1) || exit_code=$?
  exit_code=${exit_code:-0}
  
  # Always capture output for logging (escape for JSON)
  PREFLIGHT_OUTPUT=$(json_escape "$output")
  
  if [[ ${exit_code} -eq 0 ]]; then
    PREFLIGHT_OK="true"
  else
    PREFLIGHT_OK="false"
    PREFLIGHT_ERROR="Preflight check failed (exit code: ${exit_code}). See preflight_output for details."
  fi
}

# Execute preflight checks
if [[ "${PREFLIGHT_ENABLED}" != "true" ]]; then
  # Preflight disabled
  PREFLIGHT_OK="true"
elif [[ -z "${MG_ID}" || -z "${SUBSCRIPTION_ID}" ]]; then
  # Missing required parameters
  PREFLIGHT_ERROR="Management Group ID and Subscription ID are required for preflight checks."
else
  run_preflight_checks
fi

# Output JSON result for Terraform external data source
cat <<EOF
{
  "tenant_id": "${tenant_id:-}",
  "customer_object_id": "${customer_object_id:-}",
  "tags": "${TAGS_JSON}",
  "outpost_client_id": "${outpost_client_id:-}",
  "resource_suffix": "${resource_suffix:-}",
  "upload_output_url": "${upload_output_url:-}",
  "template_id": "${template_id:-}",
  "template_version": "${TEMPLATE_VERSION_JSON}",
  "connector_id": "${connector_id:-}",
  "audit_storage_allowed_ips": "${audit_storage_allowed_ips:-}",
  "audience": "${audience:-}",
  "collector_sa_unique_id": "${collector_sa_unique_id:-}",
  "preflight_ok": "${PREFLIGHT_OK}",
  "preflight_error": "${PREFLIGHT_ERROR}",
  "preflight_output": "${PREFLIGHT_OUTPUT}",
  "grant_cmd": "",
  "login_message": ""
}
EOF