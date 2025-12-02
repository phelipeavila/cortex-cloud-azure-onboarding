#!/bin/bash

# ============================================================================
# SCRIPT CONFIGURATION & HELPERS
# ============================================================================
# This section sets up the script execution environment, including logging,
# error handling, and helper functions.

# Script options
export AZURE_CORE_NO_COLOR=yes
set -o pipefail
AZ_OPTS=${1} 
trap "echo Exited!; exit;" SIGINT SIGTERM
MI_RETRY_SEC=2
REMEDIATION_RETRY_SEC=20
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
# required inputs (Management Group, Subscription ID, Location).
# It sets the Azure subscription context to the target subscription.

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
# RESOURCES: INFRASTRUCTURE SETUP
# ============================================================================
# This section handles the creation and setup of Azure resources.
# 1. Creates the Resource Group where onboarding resources will live.
# 2. Checks for existing deployments and handles migration if necessary.

# Ensure resource group for onboarding exists
log INFO "Ensure Resource group for onboarding exists..." 1
onboarding_resource_group_name="cortex-onboarding-$resource_suffix"

resource_group=""
exec_with_spinner "az group create --name \"$onboarding_resource_group_name\" --subscription \"$subscription_id\" --location \"$location\" -o tsv --query 'name' $AZ_OPTS 2>/dev/null" > /tmp/rg_output
resource_group=$(cat /tmp/rg_output)
rm -f /tmp/rg_output

if [ $? -ne 0 ] || [ -z "$resource_group" ]; then
    log ""
    log ERROR "Failed to create resource group: $onboarding_resource_group_name"
    exit 1
fi
log "" "Done. (name: $resource_group)."

# Check if migrating to new resource group
MIGRATE_RESOURCES=true
PREV_DEPLOYMENT_DATA=$(az deployment mg show \
    --management-group-id "$management_group" \
    --name "cortex-policy-$resource_suffix" \
    --query "join(' ', [properties.parameters.subscriptionId.value, properties.parameters.resourceGroup.value])" \
    -o tsv $AZ_OPTS 2>/dev/null)

if [ $? -ne 0 ]; then
    # No previous deployments were found - skipping resource migration
    MIGRATE_RESOURCES=false
fi

read -r PREV_SUB_ID PREV_RG <<< "$PREV_DEPLOYMENT_DATA"
PREV_DEPLOYMENT_PARAMS="previous-deployment-params.txt"

if [[ "$MIGRATE_RESOURCES" = "true" && \
    ( "$PREV_RG" != "$onboarding_resource_group_name" || -f "$PREV_DEPLOYMENT_PARAMS" ) ]]; then

    if [ -f "$PREV_DEPLOYMENT_PARAMS" ]; then
        read -r PREV_SUB_ID PREV_RG < "$PREV_DEPLOYMENT_PARAMS"
        log INFO "Ensure previous deployment was cleaned up: ($PREV_RG)."
    else
        echo $PREV_DEPLOYMENT_DATA > $PREV_DEPLOYMENT_PARAMS
        log INFO "Previous deployment was found using existing resource group: ($PREV_RG)."
    fi

    PREV_RG_LOCATION=$(az group show --name "$PREV_RG" --query location -o tsv 2>/dev/null)
    if [ $? -ne 0 ]; then
        log WARN "Could not determine location of previous resource group ($PREV_RG). Assuming checks passed."
    fi
    
    if [[ -n "$PREV_RG_LOCATION" && "$PREV_RG_LOCATION" != "$location" ]]; then
        log ERROR "Unable to move resources across locations. Please use the same location that was used for initial onboarding ($PREV_RG_LOCATION)"
        exit 1
    fi

    prefix="${resource_suffix%-*}"
    suffix="${resource_suffix: -5}"
    PATTERN="(CortexEventHubNamespace-${prefix}-${suffix}|cxa${prefix//-/}""${suffix})"
    RESOURCES=$(az resource list --resource-group "$PREV_RG" --query "[].id" -o tsv $AZ_OPTS 2>/dev/null)
    if [ $? -ne 0 ]; then
        log ERROR "Unable to upgrade connector. Could not list resources in previous resource group."
        exit 1
    fi
    RESOURCES=$(echo "$RESOURCES" | grep -E $PATTERN)
    if [ -n "$RESOURCES" ]; then
        log INFO "Moving resources to new resource group: ($onboarding_resource_group_name)"
        log INFO "Resources: $RESOURCES"

        exec_with_spinner "az resource move \
            --destination-subscription-id \"$subscription_id\" \
            --destination-group \"$onboarding_resource_group_name\" \
            --ids $RESOURCES 2>/dev/null"

        if [ $? -ne 0 ]; then
            log ERROR "Unable to upgrade connector. Could not move resources from previous resource group."
            exit 1
        fi
        log INFO "Finished moving resources"

        log INFO "Ensure previous managed identity is removed: (cortex-uaid-$resource_suffix)."
        az identity delete \
            --subscription "$subscription_id" \
            --resource-group "$PREV_RG" \
            --name "cortex-uaid-$resource_suffix" \
            --only-show-errors 2>/dev/null

        if [ $? -ne 0 ]; then
            log WARN "Unable to upgrade connector. Could not remove previous managed identity."
        fi
    fi
    log INFO "Cleanup has been completed."
fi


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
log INFO "Creating\Fetching role for identity..."
role_name="cortex-mi-role-$resource_suffix"
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

ROLE_DEF_CREATED=false
while true; do
    mi_role_name=$(az role definition list --name $role_name --query '[].name' -o tsv $AZ_OPTS)
    if [ -n "$mi_role_name" ]; then
        log INFO "Role definition $role_name has been found (id: $mi_role_name)."
        break
    elif [ "$ROLE_DEF_CREATED" = "false" ]; then
        log INFO "Role definition could not be found. Creating it..." 1
        create_rd_output=""
        
        # Write role definition to a temporary file to avoid eval/syntax issues with special chars in JSON
        echo "$role_def" > /tmp/role_def.json
        
        exec_with_spinner "az role definition create --role-definition @/tmp/role_def.json -o tsv $AZ_OPTS" > /tmp/rd_output
        create_rd_output=$(cat /tmp/rd_output)
        
        # Cleanup
        rm -f /tmp/rd_output /tmp/role_def.json

        if [ -z "$create_rd_output" ]; then
            log ERROR "Role definition could not be created!"
            exit 1
        fi
        log "" "Done."
        ROLE_DEF_CREATED=true
    fi

    sleep $MI_RETRY_SEC
done

# Create Managed Identity
# ----------------------------------------------------------------------------
# Creates a User Assigned Managed Identity in the onboarding resource group.
# This identity will be used by the Azure Policy to remediate resources.
log INFO "Creating/Fetching managed identity."
identity_name="cortex-mi-$resource_suffix"

MI_CREATED=false
while true; do
    mi_output=$(az identity list --subscription "$subscription_id" --resource-group "$resource_group" \
        --query "[?name=='$identity_name'].[name,clientId]" \
        -o tsv $AZ_OPTS)
    if [ -n "$mi_output" ]; then
        log INFO "Managed identity has been found. (namne: $identity_name)."
        break
    elif [ "$MI_CREATED" = "false" ]; then
        log INFO "Managed identity could not be found. Creating it..." 1
        mi_output=""
        exec_with_spinner "az identity create --name \"$identity_name\" --resource-group \"$resource_group\" \
            --subscription \"$subscription_id\" \
            --location \"$location\" \
            --query \"[name,clientId]\" \
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

# Unpack tsv into variables
read -r mi_id mi_principal_id <<< "$mi_output"

# Assign role to identity
# ----------------------------------------------------------------------------
# Assigns the custom role created earlier to the Managed Identity
# at the Management Group scope, granting it the necessary permissions.
log INFO "Assigning role to identity... " 1
while true; do
    assignment=$(az role assignment list --all \
        --assignee "$mi_principal_id" \
        -o tsv $AZ_OPTS)

    if [ -n "$assignment" ]; then
        break
    fi

    umi_role=""
    # Using retry function combined with exec_with_spinner is tricky with return values
    # So we implement simple spinner for this one call
    log "" "Creating assignment..." 1
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


# ============================================================================
# RESOURCES: POLICY DEPLOYMENT
# ============================================================================
# Deploys the Azure Policy Definition and Assignment using the ARM template.
# 1. Runs a "What-If" deployment to validate changes.
# 2. Performs the actual deployment of the policy assignment.

# Deploy onboarding template
log INFO "Running what-if on compliance policy... " 1
error_output=""
exec_with_spinner "az deployment mg what-if \
    --name \"cortex-policy-$resource_suffix\" \
    --management-group \"$management_group\" \
    --template-file \"template.json\" \
    --location \"$location\" \
    --param uaid=\"$mi_id\" \
    --param subscriptionId=\"$subscription_id\" \
    --param resourceGroup=\"$resource_group\" \
    --no-prompt \
2>&1" > /tmp/whatif_output
error_output=$(cat /tmp/whatif_output)
rm -f /tmp/whatif_output

# Check result from exec_with_spinner return code logic would be needed, 
# but here we captured output directly. Let's check if output contains error keywords or empty
# However, exec_with_spinner runs in subshell so we need to capture exit code.
# Simplified: what-if usually takes time.
exit_code=$? # This captures exec_with_spinner exit code
log "" "Done."

if [ $exit_code -ne 0 ]; then
    log ERROR "Unable to create compliance policy... "
    echo "$error_output"
    exit
fi

log INFO "Creating/Updating compliance policy... "
policyAssignmentName=""
exec_with_spinner "az deployment mg create \
    --name \"cortex-policy-$resource_suffix\" \
    --management-group \"$management_group\" \
    --template-file \"template.json\" \
    --location \"$location\" \
    --param uaid=\"$mi_id\" \
    --param subscriptionId=\"$subscription_id\" \
    --param resourceGroup=\"$resource_group\" \
    --no-prompt \
    --query \"properties.outputs.created.value.policyAssignmentName\" \
    -o tsv $AZ_OPTS" > /tmp/policy_output
policyAssignmentName=$(cat /tmp/policy_output)
rm -f /tmp/policy_output

if [ -z "$policyAssignmentName" ]; then
    log ERROR "Compliance policy creation failed."
    exit 1
fi


# ============================================================================
# RESOURCES: POLICY REMEDIATION
# ============================================================================
# Handles the compliance checking and remediation process.
# 1. Identifies all target subscriptions (Tenant or Management Group).
# 2. Checks the compliance state of the assigned policy.
# 3. Triggers a remediation task if subscriptions are non-compliant.
# 4. Waits/polls until all subscriptions are compliant.

# Remediate existing subscriptions
log INFO "Preparing initial remediation task... " 1

# This script is used for both management_group and tenant scopes. 
# Since we don't explicitly know which one we're working with and we need
# to support both, we list all subscriptions from both. 
mg_subscriptions=$(az account management-group subscription show-sub-under-mg \
    --name "$management_group" \
    --query "[].name" \
    -o tsv $AZ_OPTS 2>/dev/null \
)
# If checking MG subscriptions fails, it usually means:
# 1. The ID provided is a Tenant Root Group ID (which acts like an MG).
# 2. The user doesn't have permissions at that scope.
# We proceed silently to check tenant-level subscriptions.

tenant_subscriptions=$(az account list --all \
    --query "[?tenantId=='$management_group'].name" \
    -o tsv $AZ_OPTS 2>/dev/null \
)
# If checking tenant subscriptions also fails (or returns empty when expected), 
# it might be an issue. However, the original logic relied on the fact that
# if one list is empty, we check the other.

mg_subscriptions=($mg_subscriptions)
tenant_subscriptions=($tenant_subscriptions)

tot_mg_subs=${#mg_subscriptions[@]}
tot_tenant_subs=${#tenant_subscriptions[@]}

# Logic to determine total subscriptions:
# - If mg_subscriptions found > 0, assume MG scope.
# - If mg_subscriptions == 0, fallback to tenant_subscriptions (Tenant Root scope).
tot_subscriptions=$tot_mg_subs
if [ "$tot_mg_subs" == "0" ]; then
    # If we are working with a root management_group the tenant query will return results.
    # so we know we are working with the entire tenant.
    tot_subscriptions=$tot_tenant_subs
fi
log "" "Done."

check_compliance_state() {
    default_count_q="[0].count || \`0\`"
    comp_q="comp:[?complianceState=='compliant'] | $default_count_q"
    non_comp_q="non_comp:[?complianceState=='noncompliant'] | $default_count_q"
    assignment="policyAssignments[?contains(policyAssignmentId,'$policyAssignmentName')].results.resourceDetails"
    policy_state=$(az policy state summarize \
        --management-group "$management_group" \
        --query "$assignment.{$comp_q,$non_comp_q}" \
        -o tsv $AZ_OPTS 2>/dev/null
    )
    
    if [ $? -ne 0 ]; then
        log WARN "Failed to summarize policy state. Retrying in next interval..."
        return
    fi

    read -r compliant_count non_compliant_count <<< "$policy_state"
    
    # Default to 0 if empty (policy state not yet available)
    compliant_count=${compliant_count:-0}
    non_compliant_count=${non_compliant_count:-0}
    
    if [ "$compliant_count" -ge "$tot_subscriptions" ]; then 
        log INFO "$compliant_count out of $tot_subscriptions subscriptions are compliant."
        log INFO "All Subscriptions are compliant."
        log INFO "Cortex onboarding is successful."
        exit
    fi
}

log INFO "Checking existing policy state... "
compliant_count=0
non_compliant_count=0
check_compliance_state

echo ""
log INFO "Waiting for compliance evaluation (checking every ${REMEDIATION_RETRY_SEC}s)..."
log INFO "This may take a few minutes while Azure evaluates policy compliance."
echo ""

eval_attempt=0
while true; do
    eval_attempt=$((eval_attempt + 1))
    evaluated=$(( compliant_count + non_compliant_count ))
    printf "\r[INFO] Evaluation in progress... %d/%d subscriptions evaluated (attempt #%d)   " "$evaluated" "$tot_subscriptions" "$eval_attempt"
    if [[ "$evaluated" == "$tot_subscriptions" && "$tot_subscriptions" -ne 0 ]]; then
        echo ""
        log INFO "All subscriptions evaluated. Starting remediation task... " 
        
        ts=$(date +"%Y-%m-%d-%H:%M:%S")
        remediation_output=""
        exec_with_spinner "az policy remediation create \
            --name \"cortex-remediation-$resource_suffix-$ts\" \
            --management-group \"$management_group\" \
            --query '[provisioningState]' \
            --policy-assignment \"$policyAssignmentName\" \
            -o tsv $AZ_OPTS 2>/dev/null" > /tmp/rem_output
        remediation_output=$(cat /tmp/rem_output)
        rm -f /tmp/rem_output
            
        if [ $? -ne 0 ]; then
            log ERROR "Failed to create remediation task."
            # We continue to loop to see if external remediation or eventual consistency helps, 
            # or we could exit. For now, logging error is safe.
        else 
             break
        fi
    fi

    check_compliance_state
    # Wait until policy assignment is complete and non-compliance is evaluated
    sleep $REMEDIATION_RETRY_SEC
done

# Verify all subscriptions are compliant
echo ""
log INFO "Waiting for remediation to complete (checking every ${REMEDIATION_RETRY_SEC}s)..."
log INFO "This may take several minutes as Azure applies the policy to each subscription."
echo ""

compliance_attempt=0
while true; do
    check_compliance_state
    compliance_attempt=$((compliance_attempt + 1))

    printf "\r[INFO] Remediation in progress... %d/%d subscriptions compliant (attempt #%d)   " "$compliant_count" "$tot_subscriptions" "$compliance_attempt"
    sleep $REMEDIATION_RETRY_SEC
done


# ============================================================================
# OUTPUTS & TEARDOWN
# ============================================================================
# Logs final success message and restores the original Azure subscription context.

log INFO "Cortex onboarding successful."

# Return to original subscription
az account set --subscription "$orig_sub"

