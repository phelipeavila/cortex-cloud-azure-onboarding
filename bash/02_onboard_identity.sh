#!/bin/bash

# ============================================================================
# SCRIPT CONFIGURATION & HELPERS
# ============================================================================
# This section sets up the script execution environment, including logging,
# error handling, and helper functions for retrying commands.

# Script options
export AZURE_CORE_NO_COLOR=yes
set -o pipefail
AZ_OPTS=${1} 
trap "echo Exited!; exit;" SIGINT SIGTERM
MI_RETRY_SEC=2
CMD_TOT_RETRY=5
CMD_RETRY_SEC=5

# Log function
log() {
    local new_line=${3:+-n}
    local level="${1:+[$1] }"
    echo $new_line "$level$2"
}

# Spinner function to show activity
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr" >&2
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b" >&2
    done
    printf "    \b\b\b\b" >&2
}

# Helper to execute command with spinner
exec_with_spinner() {
    local cmd="$1"
    # Run command in background
    eval "$cmd" &
    local pid=$!
    spinner $pid
    wait $pid
    return $?
}

# Generic retry
retry() {
    local attempt=1
    until output=$("$@" 2>&1); do
        if (( attempt >= CMD_TOT_RETRY )); then
            exit 1
        fi
        sleep "$CMD_RETRY_SEC"
        ((attempt++))
    done
    echo "$output"
}

# Verify Azure CLI is installed and authenticated
if ! command -v az >/dev/null 2>&1; then
    log ERROR "Azure CLI is not installed. Please install Azure CLI before running this script."
    exit 1
fi
log INFO "Azure CLI is installed."

if ! az account show >/dev/null 2>&1; then
    log ERROR "Azure CLI is not authenticated. Please login to Azure CLI before running this script."
    exit 1
fi
log INFO "Azure CLI is authenticated."


# ============================================================================
# INPUT VARIABLES & INITIALIZATION
# ============================================================================
# This section loads configuration parameters and prompts the user for
# required inputs (Management Group, Subscription ID, Location) if they
# are not already provided. It also sets the Azure subscription context.

# Load parameters
source ./parameters.sh 2> /dev/null
if [ $? -ne 0 ]; then
    log ERROR "Parameters file not found!"
    exit 1
fi

# Helper to get input with default from parameters.sh or prompt
get_input() {
    local var_name=$1
    local prompt_text=$2
    local current_val=${!var_name}

    if [ -n "$current_val" ]; then
        read -p "$prompt_text [$current_val]: " input
        if [ -n "$input" ]; then
            eval $var_name=\"$input\"
        fi
    else
        while [ -z "${!var_name}" ]; do
            read -p "$prompt_text: " input
            eval $var_name=\"$input\"
        done
    fi
}

# User inputs
get_input "management_group" "Please enter management group id (or tenant id)"
get_input "subscription_id" "Please enter subscription id"

valid_regions=$(az account list-locations --query "[].name" -o tsv)
if [ $? -ne 0 ]; then
    log ERROR "Unable to retrieve Azure locations."
    exit 1
fi

# Special handling for location to include validation and default
if [ -n "$location" ]; then
    default_location=$location
else
    default_location="eastus"
fi

while true; do
    if [ -n "$location" ]; then
        read -p "Please enter location (default: $default_location): " location_input
    else
        read -p "Please enter location (default: $default_location): " location_input
    fi
    
    location_input=${location_input:-$default_location}
    
    if echo "$valid_regions" | grep -qx "$location_input"; then
        location=$location_input
        break
    else
        log ERROR "Invalid region format. Use canonical form (e.g., eastus, westus2)."
        # Reset location if it was invalid so we loop
        if [ "$location" == "$location_input" ]; then
             location=""
             default_location="eastus"
        fi
    fi
done

# Set default subscription
orig_sub=$(az account show -o tsv --query 'name')
az account set --subscription "$subscription_id"
if [ $? -ne 0 ]; then
    log ERROR "Selected subscription_id was not found"
    exit 1
fi


# ============================================================================
# RESOURCES: VALIDATION
# ============================================================================
# Ensures that the prerequisites (Preparation Script execution) have been met.

# Derive Resource Group name
onboarding_resource_group_name="cortex-onboarding-$resource_suffix"
resource_group=$onboarding_resource_group_name

log INFO "Verifying resources exist..."
# Verify Resource Group
if ! az group show --name "$resource_group" --subscription "$subscription_id" >/dev/null 2>&1; then
    log ERROR "Resource group $resource_group not found. Please run 01_onboard_setup.sh first."
    exit 1
fi
log INFO "Resources verified."


# ============================================================================
# RESOURCES: IDENTITY SETUP
# ============================================================================
# This section handles the creation and setup of Identity resources.
# 1. Grants Graph API permissions to the enterprise application.
# 2. Creates/Updates the custom Role Definition for the Managed Identity.
# 3. Creates the User Assigned Managed Identity.
# 4. Assigns the custom role to the Managed Identity at the MG scope.

# Granting enterprise application GraphAPI permissions
# ----------------------------------------------------------------------------
# Reads required Graph API roles from graphAPIRoles.json and assigns them
# to the Cortex Enterprise Application Service Principal.
log INFO "Ensure enterprise application has GraphAPI permissions..." 1
# Read JSON array into Bash array

graphAPIRoles=()

while IFS= read -r line; do
  line=$(echo "$line" | sed -E 's/[[:space:]"]+//g')
  if [[ "$line" =~ ^[a-f0-9\-]{36}$ ]]; then
    graphAPIRoles+=("$line")
  fi
done < <(grep -oE '"[a-f0-9\-]{36}"' graphAPIRoles.json)

graphAPIID=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query 'id' -o tsv)
if [ $? -ne 0 ] || [ -z "$graphAPIID" ]; then
    log ERROR "Failed to retrieve Microsoft Graph Service Principal ID."
    exit 1
fi

graphURI="https://graph.microsoft.com/v1.0/servicePrincipals/$customer_object_id/appRoleAssignments"
for role in "${graphAPIRoles[@]}"; do
    # Check if the permission already exists
    existing_assignment=$(az rest --method GET --uri "$graphURI" --resource https://graph.microsoft.com \
        --query "value[?appRoleId=='$role'].id" -o tsv 2>/dev/null)
    
    if [ -n "$existing_assignment" ]; then
        # Permission already exists, skip
        log "" "." 1
        continue
    fi
    
    # Permission doesn't exist, try to assign it
    # We add --resource https://graph.microsoft.com to ensure correct token scope in Cloud Shell
    if exec_with_spinner "az rest --method POST --uri \"$graphURI\" --resource https://graph.microsoft.com \
        --body '{ \"principalId\": \"$customer_object_id\", \"appRoleId\": \"$role\", \"resourceId\": \"$graphAPIID\" }' \
        $AZ_OPTS 2> /dev/null"; then
        log "" "." 1
    else
        log ""
        log WARN "Failed to assign Graph API role ($role) automatically. This is common in Cloud Shell if permissions are restricted."
        log WARN "Please manually grant this permission to the Enterprise Application ($customer_object_id) in Azure AD."
    fi
    done
log "" "Done."

# Create role definition for managed identity
# ----------------------------------------------------------------------------
# Defines a custom role with permissions required for Cortex to operate.
# The role is scoped to the target Management Group.
log INFO "Creating/Updating role for identity..."
role_name="cortex-mi-role-$resource_suffix"

# Define the expected permissions (sorted for comparison)
expected_actions=(
    "Microsoft.Authorization/policyAssignments/*"
    "Microsoft.Authorization/policyDefinitions/*"
    "Microsoft.Authorization/roleAssignments/*"
    "Microsoft.Authorization/roleDefinitions/*"
    "Microsoft.Compute/galleries/*"
    "Microsoft.EventHub/namespaces/*"
    "Microsoft.Insights/diagnosticSettings/*"
    "Microsoft.Resources/deployments/*"
    "Microsoft.Resources/subscriptions/read"
    "Microsoft.Resources/subscriptions/resourceGroups/*"
)

role_def=$(cat << EOF
{
    "name": "$role_name",
    "isCustom": true,
    "description": "Custom role for Managed Identity ($resource_suffix).",
    "assignableScopes": [
        "/providers/Microsoft.Management/managementGroups/${management_group}"
    ],
    "permissions": [{
        "actions": [
            "Microsoft.Resources/deployments/*",
            "Microsoft.Resources/subscriptions/resourceGroups/*",
            "Microsoft.Resources/subscriptions/read",
            "Microsoft.Authorization/roleDefinitions/*",
            "Microsoft.Authorization/roleAssignments/*",
            "Microsoft.Authorization/policyDefinitions/*",
            "Microsoft.Authorization/policyAssignments/*",
            "Microsoft.EventHub/namespaces/*",
            "Microsoft.Insights/diagnosticSettings/*",
            "Microsoft.Compute/galleries/*"
        ]
    }]
}
EOF
)

# Check if role definition exists
existing_role=$(az role definition list --name "$role_name" --query '[0]' -o json $AZ_OPTS 2>/dev/null)

if [ -n "$existing_role" ] && [ "$existing_role" != "null" ]; then
    mi_role_name=$(echo "$existing_role" | grep -o '"name": *"[^"]*"' | head -1 | sed 's/"name": *"\([^"]*\)"/\1/')
    log INFO "Role definition $role_name found (id: $mi_role_name). Verifying permissions..."
    
    # Get current actions from the existing role (sorted)
    current_actions=$(echo "$existing_role" | grep -o '"actions": *\[[^]]*\]' | head -1 | \
        grep -oE '"Microsoft\.[^"]+' | tr -d '"' | sort)
    
    # Compare sorted actions
    expected_sorted=$(printf '%s\n' "${expected_actions[@]}" | sort)
    
    if [ "$current_actions" != "$expected_sorted" ]; then
        log WARN "Role permissions differ from expected:"
        
        # Find missing permissions (in expected but not in current)
        missing=$(comm -23 <(echo "$expected_sorted") <(echo "$current_actions"))
        if [ -n "$missing" ]; then
            log WARN "  Missing permissions:"
            while IFS= read -r perm; do
                log WARN "    + $perm"
            done <<< "$missing"
        fi
        
        # Find extra permissions (in current but not in expected)
        extra=$(comm -13 <(echo "$expected_sorted") <(echo "$current_actions"))
        if [ -n "$extra" ]; then
            log WARN "  Extra permissions (will be removed):"
            while IFS= read -r perm; do
                log WARN "    - $perm"
            done <<< "$extra"
        fi
        
        log INFO "Updating role definition..."
        
        # Get the role ID for update
        role_id=$(echo "$existing_role" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/"id": *"\([^"]*\)"/\1/')
        
        # Create update definition with id included
        update_def=$(cat << EOF
{
    "id": "$role_id",
    "name": "$role_name",
    "isCustom": true,
    "description": "Custom role for Managed Identity ($resource_suffix).",
    "assignableScopes": [
        "/providers/Microsoft.Management/managementGroups/${management_group}"
    ],
    "permissions": [{
        "actions": [
            "Microsoft.Resources/deployments/*",
            "Microsoft.Resources/subscriptions/resourceGroups/*",
            "Microsoft.Resources/subscriptions/read",
            "Microsoft.Authorization/roleDefinitions/*",
            "Microsoft.Authorization/roleAssignments/*",
            "Microsoft.Authorization/policyDefinitions/*",
            "Microsoft.Authorization/policyAssignments/*",
            "Microsoft.EventHub/namespaces/*",
            "Microsoft.Insights/diagnosticSettings/*",
            "Microsoft.Compute/galleries/*"
        ]
    }]
}
EOF
)
        echo "$update_def" > /tmp/role_def.json
        
        if exec_with_spinner "az role definition update --role-definition @/tmp/role_def.json -o tsv $AZ_OPTS 2>/tmp/rd_error" > /tmp/rd_output; then
            log INFO "Role definition updated successfully."
        else
            log WARN "Could not update role definition. Continuing with existing permissions."
            if [ -s /tmp/rd_error ]; then
                log WARN "Error details:"
                while IFS= read -r line; do
                    log WARN "  $line"
                done < /tmp/rd_error
            fi
        fi
        rm -f /tmp/rd_output /tmp/role_def.json /tmp/rd_error
    else
        log INFO "Role permissions are correct."
    fi
else
    # Role doesn't exist, create it
    log INFO "Role definition not found. Creating it..." 1
    
    echo "$role_def" > /tmp/role_def.json
    exec_with_spinner "az role definition create --role-definition @/tmp/role_def.json -o tsv $AZ_OPTS" > /tmp/rd_output
    create_rd_output=$(cat /tmp/rd_output)
    rm -f /tmp/rd_output /tmp/role_def.json

    if [ -z "$create_rd_output" ]; then
        log ERROR "Role definition could not be created!"
        exit 1
    fi
    log "" "Done."
    
    # Wait for role definition to propagate
    log INFO "Waiting for role definition to propagate..."
    for i in {1..10}; do
        mi_role_name=$(az role definition list --name "$role_name" --query '[].name' -o tsv $AZ_OPTS 2>/dev/null)
        if [ -n "$mi_role_name" ]; then
            log INFO "Role definition $role_name is ready (id: $mi_role_name)."
            break
        fi
        sleep $MI_RETRY_SEC
    done
    
    if [ -z "$mi_role_name" ]; then
        log ERROR "Role definition was created but could not be verified!"
        exit 1
    fi
fi

# Create Managed Identity
# ----------------------------------------------------------------------------
# Creates a User Assigned Managed Identity in the onboarding resource group.
# This identity will be used by the Azure Policy to remediate resources.
log INFO "Creating/Fetching managed identity."
identity_name="cortex-mi-$resource_suffix"

MI_CREATED=false
while true; do
    # Query for principalId (object ID) - required for role assignments
    mi_output=$(az identity list --subscription "$subscription_id" --resource-group "$resource_group" \
        --query "[?name=='$identity_name'].[name,principalId]" \
        -o tsv $AZ_OPTS)
    if [ -n "$mi_output" ]; then
        log INFO "Managed identity has been found. (name: $identity_name)."
        break
    elif [ "$MI_CREATED" = "false" ]; then
        log INFO "Managed identity could not be found. Creating it..." 1
        mi_output=""
        exec_with_spinner "az identity create --name \"$identity_name\" --resource-group \"$resource_group\" \
            --subscription \"$subscription_id\" \
            --location \"$location\" \
            --query \"[name,principalId]\" \
            -o tsv $AZ_OPTS" > /tmp/mi_output
        mi_output=$(cat /tmp/mi_output)
        rm -f /tmp/mi_output

        if [ -z "$mi_output" ]; then
            log ERROR "Managed identity could not be created!"
            exit 1
        fi
        log "" "Done."
        MI_CREATED=true
    fi

    sleep $MI_RETRY_SEC
done

# Unpack tsv into variables (name, principalId/objectId)
read -r mi_name mi_principal_id <<< "$mi_output"

# Assign role to identity
# ----------------------------------------------------------------------------
# Assigns the custom role created earlier to the Managed Identity
# at the Management Group scope, granting it the necessary permissions.
log INFO "Checking role assignment for identity..."
while true; do
    # Check if the SPECIFIC role is assigned (not just any role)
    assignment=$(az role assignment list --all \
        --assignee "$mi_principal_id" \
        --role "$mi_role_name" \
        --scope "/providers/Microsoft.Management/managementGroups/$management_group" \
        -o tsv $AZ_OPTS 2>/dev/null)

    if [ -n "$assignment" ]; then
        log INFO "Role '$mi_role_name' is already assigned to identity."
        break
    fi

    umi_role=""
    # Role not assigned, create it
    log INFO "Role '$mi_role_name' not assigned. Creating assignment..." 1
    exec_with_spinner "az role assignment create \
      --assignee \"$mi_principal_id\" \
      --role \"$mi_role_name\" \
      --scope \"/providers/Microsoft.Management/managementGroups/$management_group\" \
      -o tsv $AZ_OPTS 2>/dev/null" > /tmp/umi_role_output
    umi_role=$(cat /tmp/umi_role_output)
    rm -f /tmp/umi_role_output

    if [ -z "$umi_role" ]; then
        log "" "Unable to assign role!"
        exit 1
    fi
done
log "" "Done."

log INFO "Identity setup complete. Please run 03_onboard_policy.sh to complete the onboarding."

# Return to original subscription
az account set --subscription "$orig_sub"
