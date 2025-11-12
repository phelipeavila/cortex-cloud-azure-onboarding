# ============================================================================
# TERRAFORM CONFIGURATION
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

# ============================================================================
# PROVIDER CONFIGURATION
# ============================================================================

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  use_cli                    = true
  skip_provider_registration = true
}

provider "azuread" {
  use_cli = true
}

# ============================================================================
# INPUT VARIABLES
# ============================================================================

variable "tenant_id" {
  description = "Tenant ID for tenant-level onboarding. Provide either tenant_id OR management_group_id, not both."
  type        = string
  default     = ""
}

variable "management_group_id" {
  description = "Management Group ID for management group-level onboarding. Provide either tenant_id OR management_group_id, not both."
  type        = string
  default     = ""
}

variable "subscription_id" {
  description = "Subscription ID to host the onboarding resource group and managed identity"
  type        = string
}

variable "location" {
  description = "Azure location for creating onboarding resources"
  type        = string
  default     = "eastus"
}

variable "preflight_enabled" {
  description = "Run permission preflight checks before deployment"
  type        = bool
  default     = true
}

# ============================================================================
# DATA SOURCES
# ============================================================================

# Bootstrap script: loads parameters.sh and runs preflight checks
data "external" "bootstrap" {
  program = [
    "${path.module}/bootstrap.sh",
    local.target_mg,
    var.subscription_id,
    var.preflight_enabled ? "true" : "false",
    local.tenant_id_provided ? "tenant" : "mg"
  ]
}

# Read Graph API roles configuration
data "local_file" "graph_roles" {
  filename = "${path.module}/graphAPIRoles.json"
}

# Azure subscription information
data "azurerm_subscription" "main" {
  subscription_id = var.subscription_id
}

# Current Azure client configuration
data "azurerm_client_config" "current" {}

# Microsoft Graph service principal (for role assignments)
data "azuread_service_principal" "graph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# ============================================================================
# LOCALS: Configuration and Parameter Building
# ============================================================================

locals {
  # --------------------------------------------------------------------------
  # Parse bootstrap output and external data
  # --------------------------------------------------------------------------
  graph_roles      = jsondecode(data.local_file.graph_roles.content).graphAPIRoles
  parameters       = data.external.bootstrap.result
  tags             = jsondecode(local.parameters.tags)
  template_version = jsondecode(local.parameters.template_version)

  # --------------------------------------------------------------------------
  # Resource naming
  # --------------------------------------------------------------------------
  onboarding_resource_group_name = "cortex-onboarding-${local.parameters.resource_suffix}"
  identity_name                  = "cortex-mi-${local.parameters.resource_suffix}"
  role_name                      = "cortex-mi-role-${local.parameters.resource_suffix}"

  # --------------------------------------------------------------------------
  # Onboarding scope validation and target determination
  # --------------------------------------------------------------------------
  tenant_id_provided        = trimspace(var.tenant_id) != ""
  management_group_provided = trimspace(var.management_group_id) != ""

  validation_error = local.tenant_id_provided && local.management_group_provided ? "Error: Both tenant_id and management_group_id are provided. You must provide only ONE of: tenant_id (for tenant-level onboarding) OR management_group_id (for management group-level onboarding)." : ""

  # Determine target MG: tenant_id is used directly as the tenant root MG ID
  target_mg = local.tenant_id_provided ? trimspace(var.tenant_id) : trimspace(var.management_group_id)

  # --------------------------------------------------------------------------
  # Template detection and parameter building
  # --------------------------------------------------------------------------
  template_candidates = fileset(path.module, "template.json")
  template_path       = "${path.module}/${tolist(local.template_candidates)[0]}"
  template_doc        = jsondecode(file(local.template_path))
  template_params     = toset(keys(lookup(local.template_doc, "parameters", {})))

  # Base parameters (always required)
  base_params = {
    resourceSuffix   = { value = local.parameters.resource_suffix }
    templateId       = { value = local.parameters.template_id }
    tenantId         = { value = local.parameters.tenant_id }
    customerObjectId = { value = local.parameters.customer_object_id }
    outpostClientId  = { value = local.parameters.outpost_client_id }
    uploadOutputUrl  = { value = local.parameters.upload_output_url }
    subscriptionId   = { value = var.subscription_id }
    resourceGroup    = { value = azurerm_resource_group.onboarding.name }
    uaid             = { value = azurerm_user_assigned_identity.cortex.name }
    tags             = { value = local.tags }
    templateVersion  = { value = local.template_version }
    connectorId      = { value = local.parameters.connector_id }
  }

  # Optional parameters (only included if present in template.json)
  optional_params = merge(
    contains(local.template_params, "auditStorageAllowedIps") ? {
      auditStorageAllowedIps = { value = local.parameters.audit_storage_allowed_ips }
    } : {},
    contains(local.template_params, "audience") ? {
      audience = { value = local.parameters.audience }
    } : {},
    contains(local.template_params, "collectorSaUniqueId") ? {
      collectorSaUniqueId = { value = local.parameters.collector_sa_unique_id }
    } : {}
  )

  # Final parameter map for ARM template deployment
  final_params = merge(local.base_params, local.optional_params)
}

# ============================================================================
# RESOURCES: Infrastructure Setup
# ============================================================================

# ----------------------------------------------------------------------------
# Resource Group
# ----------------------------------------------------------------------------
resource "azurerm_resource_group" "onboarding" {
  name     = local.onboarding_resource_group_name
  location = var.location
  tags     = local.tags
}

# ----------------------------------------------------------------------------
# Managed Identity
# ----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "cortex" {
  name                = local.identity_name
  resource_group_name = azurerm_resource_group.onboarding.name
  location            = azurerm_resource_group.onboarding.location
  tags                = local.tags
}

# ----------------------------------------------------------------------------
# Custom Role Definition
# ----------------------------------------------------------------------------
resource "azurerm_role_definition" "cortex_mi_role" {
  name        = local.role_name
  scope       = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  description = "Custom role for Managed Identity (${local.parameters.resource_suffix})."

  permissions {
    actions = [
      "Microsoft.Resources/deployments/*",
      "Microsoft.Resources/subscriptions/resourceGroups/*",
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Authorization/roleDefinitions/*",
      "Microsoft.Authorization/roleAssignments/*",
      "Microsoft.Authorization/policyDefinitions/*",
      "Microsoft.Authorization/policyAssignments/*",
      "Microsoft.Authorization/*/read",
      "Microsoft.EventHub/namespaces/*",
      "Microsoft.Insights/diagnosticSettings/*"
    ]
  }

  assignable_scopes = [
    "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  ]
}

# ----------------------------------------------------------------------------
# Role Assignment: Custom Role to Managed Identity
# ----------------------------------------------------------------------------
resource "azurerm_role_assignment" "cortex_mi_role_assignment" {
  scope              = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  role_definition_id = azurerm_role_definition.cortex_mi_role.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.cortex.principal_id

  depends_on = [
    azurerm_role_definition.cortex_mi_role,
    azurerm_user_assigned_identity.cortex
  ]
}

# ----------------------------------------------------------------------------
# Microsoft Graph API Role Assignments
# ----------------------------------------------------------------------------
resource "azuread_app_role_assignment" "graph_roles" {
  for_each = toset(local.graph_roles)

  app_role_id         = each.value
  principal_object_id = local.parameters.customer_object_id
  resource_object_id  = data.azuread_service_principal.graph.object_id
}

# ============================================================================
# RESOURCES: Policy Deployment
# ============================================================================

# ----------------------------------------------------------------------------
# ARM Template Deployment at Management Group Scope
# ----------------------------------------------------------------------------
resource "azurerm_management_group_template_deployment" "cortex_policy" {
  name                = "cortex-policy-${local.parameters.resource_suffix}"
  management_group_id = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  location            = var.location

  template_content   = file(local.template_path)
  parameters_content = jsonencode(local.final_params)

  lifecycle {
    # Validate exactly one template.json exists
    precondition {
      condition     = length(local.template_candidates) == 1
      error_message = "Expected exactly one template.json in the current directory."
    }

    # Validate only one onboarding scope is provided
    precondition {
      condition     = local.validation_error == ""
      error_message = local.validation_error
    }

    # Validate at least one onboarding scope is provided
    precondition {
      condition     = length(local.target_mg) > 0
      error_message = "You must provide either tenant_id (for tenant-level onboarding) or management_group_id (for management group-level onboarding)."
    }

    # Validate preflight checks passed (if enabled)
    precondition {
      condition     = var.preflight_enabled ? try(data.external.bootstrap.result.preflight_ok == "true", true) : true
      error_message = "Preflight failed: ${try(data.external.bootstrap.result.preflight_error, "unknown error")}${try(data.external.bootstrap.result.grant_cmd != "", false) ? "\n\nTo grant the required permissions, run:\n${data.external.bootstrap.result.grant_cmd}" : ""}"
    }
  }

  depends_on = [
    azurerm_user_assigned_identity.cortex,
    azurerm_role_definition.cortex_mi_role,
    azurerm_role_assignment.cortex_mi_role_assignment
  ]
}

# ============================================================================
# LOCALS: Deployment Outputs
# ============================================================================

locals {
  deployment_outputs     = jsondecode(azurerm_management_group_template_deployment.cortex_policy.output_content)
  policy_assignment_name = local.deployment_outputs.created.value.policyAssignmentName
}

# ============================================================================
# RESOURCES: Policy Remediation
# ============================================================================

# ----------------------------------------------------------------------------
# Policy Remediation Task
# ----------------------------------------------------------------------------
resource "azurerm_management_group_policy_remediation" "cortex_remediation" {
  name                 = "cortex-remediation-${local.parameters.resource_suffix}-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  management_group_id  = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  policy_assignment_id = "/providers/Microsoft.Management/managementGroups/${local.target_mg}/providers/Microsoft.Authorization/policyAssignments/${local.policy_assignment_name}"

  depends_on = [
    azurerm_management_group_template_deployment.cortex_policy
  ]
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "resource_group_name" {
  description = "Name of the created resource group"
  value       = azurerm_resource_group.onboarding.name
}

output "managed_identity_name" {
  description = "Name of the created managed identity"
  value       = azurerm_user_assigned_identity.cortex.name
}

output "managed_identity_principal_id" {
  description = "Principal ID of the created managed identity"
  value       = azurerm_user_assigned_identity.cortex.principal_id
}

output "policy_assignment_name" {
  description = "Name of the created policy assignment"
  value       = local.policy_assignment_name
}

output "remediation_name" {
  description = "Name of the created remediation task"
  value       = azurerm_management_group_policy_remediation.cortex_remediation.name
}

output "preflight_status" {
  description = "Preflight check status and output"
  value = {
    enabled = var.preflight_enabled
    passed  = try(data.external.bootstrap.result.preflight_ok == "true", false)
    output  = try(data.external.bootstrap.result.preflight_output, "")
  }
}

output "onboarding_configuration" {
  description = "Onboarding configuration details"
  value = {
    onboarding_type     = local.tenant_id_provided ? "tenant" : "management_group"
    target_scope        = local.target_mg
    tenant_id           = var.tenant_id != "" ? var.tenant_id : null
    management_group_id = var.management_group_id != "" ? var.management_group_id : null
  }
}
