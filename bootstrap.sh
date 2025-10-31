#!/bin/bash
set -euo pipefail

# Role name to grant at management group scope (can be changed to other roles like Contributor, User Access Administrator, etc.)
MG_ADMIN_ROLE="Owner"

# Args: <management_group_id> <subscription_id> <preflight_enabled:true|false> <grant_self_mg_admin:true|false>
MG_ID="${1:-}"
SUBSCRIPTION_ID="${2:-}"
PREFLIGHT_ENABLED="${3:-true}"
GRANT_SELF_MG_ADMIN="${4:-false}"

# Load parameters.sh and convert fields that are JSON-like to valid JSON strings
if [ -f ./parameters.sh ]; then
  # shellcheck disable=SC1091
  source ./parameters.sh 2>/dev/null || true
fi

# Normalize JSON-like strings: single quotes -> double, then escape quotes for JSON embedding
json_escape() { sed 's/"/\\"/g'; }
to_json_string() { sed "s/'/\"/g" | json_escape; }

TAGS_JSON=$(echo "${tags:-}" | to_json_string)
TEMPLATE_VERSION_JSON=$(echo "${template_version:-}" | to_json_string)

# Local state file to persist temporary role assignment id between runs
ASSIGN_STATE_FILE=".mg_admin_assign_id"

# Preflight (optional)
PREFLIGHT_OK="false"
PREFLIGHT_ERROR=""
GRANTED_MG_ADMIN="false"
CLEANUP_CMD=""
LOGIN_MSG_ESCAPED=""
SKIP_FURTHER_CHECKS=""

# Preflight checks: verify CLI login, MG permissions, subscription permissions, and AAD roles
if [ "${PREFLIGHT_ENABLED}" != "true" ]; then
  # Preflight disabled: skip all checks
  PREFLIGHT_OK="true"
elif [ -z "${MG_ID}" ] || [ -z "${SUBSCRIPTION_ID}" ]; then
  # Missing required arguments for preflight
  PREFLIGHT_OK="false"
  PREFLIGHT_ERROR="Management Group ID and Subscription ID are required for preflight checks."
else
  # Check 1: Azure CLI login status
  if ! az account show >/dev/null 2>&1; then
    PREFLIGHT_OK="false"; PREFLIGHT_ERROR="Azure CLI not logged in. Run 'az login' and try again."
  else
    # Check 2: Resolve signed-in principal (user or service principal)
    OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
    if [ -z "$OBJECT_ID" ]; then
      UPN_OR_APPID=$(az account show --query user.name -o tsv 2>/dev/null || true)
      [ -n "$UPN_OR_APPID" ] && OBJECT_ID=$(az ad sp show --id "$UPN_OR_APPID" --query id -o tsv 2>/dev/null || true)
    fi
    if [ -z "$OBJECT_ID" ]; then
      PREFLIGHT_OK="false"; PREFLIGHT_ERROR="Cannot resolve signed-in principal (user or service principal). Ensure you're logged in with 'az login'."
    else
      # Check 3: Management Group permissions
      MG_ROLES=$(az role assignment list --assignee "$OBJECT_ID" --scope "/providers/Microsoft.Management/managementGroups/${MG_ID}" -o tsv --query "[].roleDefinitionName" 2>/dev/null || true)
      if ! echo "$MG_ROLES" | grep -Eiq 'Owner|User Access Administrator|Contributor'; then
        # Insufficient MG permissions: attempt to grant temporary role if enabled
        if [ "${GRANT_SELF_MG_ADMIN}" = "true" ]; then
          ASSIGN_ID=$(az role assignment create --assignee "$OBJECT_ID" --role "${MG_ADMIN_ROLE}" --scope "/providers/Microsoft.Management/managementGroups/${MG_ID}" --query id -o tsv 2>/dev/null || true)
          if [ -n "$ASSIGN_ID" ]; then
            # Successfully granted temporary role; instruct user to re-auth and rerun
            GRANTED_MG_ADMIN="true"
            CLEANUP_CMD="az role assignment delete --ids ${ASSIGN_ID}"
            echo "$ASSIGN_ID" > "$ASSIGN_STATE_FILE" 2>/dev/null || true
            PREFLIGHT_OK="false"
            PREFLIGHT_ERROR="Granted temporary ${MG_ADMIN_ROLE} at MG. Please run 'az account clear && az login --use-device-code' and rerun Terraform. On success, bootstrap will remove the temporary role."
          fi
        fi
        if [ "$GRANTED_MG_ADMIN" = "true" ]; then
          # Skip subscription/AAD checks since we're in the grant flow
          SKIP_FURTHER_CHECKS="true"
        else
          # Grant not enabled or failed; user lacks MG permissions
          PREFLIGHT_OK="false"; PREFLIGHT_ERROR="Insufficient Management Group permissions. Need Owner/User Access Administrator/Contributor on /providers/Microsoft.Management/managementGroups/${MG_ID}. Enable grant_self_mg_admin=true or have an MG Owner assign the role."
        fi
      else
        # Already has sufficient MG role; if a previous temp assignment exists, prepare same-run cleanup
        if [ -f "$ASSIGN_STATE_FILE" ]; then
          PREV_ASSIGN_ID=$(cat "$ASSIGN_STATE_FILE" 2>/dev/null | head -1)
          # Validate ID format before cleanup to prevent accidental commands
          if [ -n "$PREV_ASSIGN_ID" ] && [[ "$PREV_ASSIGN_ID" =~ ^/providers/Microsoft\. ]]; then
            # Valid temp assignment found; schedule cleanup and skip further checks
            GRANTED_MG_ADMIN="true"
            CLEANUP_CMD="az role assignment delete --ids ${PREV_ASSIGN_ID}"
            rm -f "$ASSIGN_STATE_FILE" >/dev/null 2>&1 || true
            PREFLIGHT_OK="true"
            SKIP_FURTHER_CHECKS="true"
          fi
        fi
      fi
      # Check 4 & 5: Subscription and AAD permissions (unless skipped)
      if [ "$SKIP_FURTHER_CHECKS" != "true" ]; then
        SUB_ROLES=$(az role assignment list --assignee "$OBJECT_ID" --scope "/subscriptions/${SUBSCRIPTION_ID}" --include-inherited -o tsv --query "[].roleDefinitionName" 2>/dev/null || true)
        if ! echo "$SUB_ROLES" | grep -Eiq 'Owner|Contributor'; then
          PREFLIGHT_OK="false"; PREFLIGHT_ERROR="Insufficient subscription permissions on /subscriptions/${SUBSCRIPTION_ID}. Need Owner or Contributor."
        fi
        AAD_ROLES=$(az rest --method GET --url https://graph.microsoft.com/v1.0/me/memberOf --headers Content-Type=application/json --query "value[].displayName" -o tsv 2>/dev/null || true)
        if ! echo "$AAD_ROLES" | grep -Eiq 'Application Administrator|Cloud Application Administrator|Privileged Role Administrator|Global Administrator'; then
          PREFLIGHT_OK="false"; PREFLIGHT_ERROR="Insufficient Azure AD directory role. Need Application Administrator, Cloud Application Administrator, Privileged Role Administrator, or Global Administrator to assign Graph app roles."
        fi
        # All checks passed; mark preflight as OK
        if [ -z "$PREFLIGHT_ERROR" ]; then
          PREFLIGHT_OK="true"
        fi
      fi
    fi
  fi
fi

# Output combined JSON map of string keys/values
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
  "granted_mg_admin": "${GRANTED_MG_ADMIN}",
  "cleanup_cmd": "${CLEANUP_CMD}",
  "login_message": "${LOGIN_MSG_ESCAPED:-}"
}
EOF


