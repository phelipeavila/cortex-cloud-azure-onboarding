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

log INFO "Preparation setup complete. Please run 02_onboard_identity.sh to complete the identity setup."

# Return to original subscription
az account set --subscription "$orig_sub"

