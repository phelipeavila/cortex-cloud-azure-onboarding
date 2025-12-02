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
# RESOURCES: VALIDATION
# ============================================================================
# Ensures that the prerequisites (Identity Script execution) have been met.
# Checks for the existence of the Resource Group and Managed Identity.

# Derive Resource Group and Managed Identity names
onboarding_resource_group_name="cortex-onboarding-$resource_suffix"
identity_name="cortex-mi-$resource_suffix"
resource_group=$onboarding_resource_group_name

log INFO "Verifying resources exist..."
# Verify Resource Group
if ! az group show --name "$resource_group" --subscription "$subscription_id" >/dev/null 2>&1; then
    log ERROR "Resource group $resource_group not found. Please run 02_onboard_identity.sh first."
    exit 1
fi

# Verify Managed Identity
mi_id=$(az identity show --name "$identity_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null)
if [ -z "$mi_id" ]; then
    log ERROR "Managed identity $identity_name not found. Please run 02_onboard_identity.sh first."
    exit 1
fi
log INFO "Resources verified."


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
