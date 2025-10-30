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
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Configure providers
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  use_cli = true
  skip_provider_registration = true
}

provider "azuread" {
  use_cli = true
}

provider "azapi" {
  use_cli = true
}

# Combined parameters + preflight (optional)
data "external" "bootstrap" {
  program = [
    "${path.module}/bootstrap.sh",
    local.target_mg,
    var.subscription_id,
    var.preflight_enabled ? "true" : "false",
    var.grant_self_mg_contributor ? "true" : "false"
  ]
}

# Read Graph API roles from JSON file
data "local_file" "graph_roles" {
  filename = "${path.module}/graphAPIRoles.json"
}

# Parse Graph API roles
locals {
  graph_roles = jsondecode(data.local_file.graph_roles.content).graphAPIRoles
  parameters  = data.external.bootstrap.result
  
  # Parse tags from parameters
  tags = jsondecode(local.parameters.tags)
  
  # Parse template version from parameters
  template_version = jsondecode(local.parameters.template_version)
  
  # Resource names
  onboarding_resource_group_name = "cortex-onboarding-${local.parameters.resource_suffix}"
  identity_name                  = "cortex-mi-${local.parameters.resource_suffix}"
  role_name                      = "cortex-mi-role-${local.parameters.resource_suffix}"
}

# Auto-detect template.json in the current directory and build params dynamically
locals {
  target_mg = coalesce(trimspace(var.root_management_group_id), trimspace(var.management_group))

  template_candidates = fileset(path.module, "template.json")
  template_path       = "${path.module}/${tolist(local.template_candidates)[0]}"

  template_doc    = jsondecode(file(local.template_path))
  template_params = toset(keys(lookup(local.template_doc, "parameters", {})))

  base_params = {
    resourceSuffix = { value = local.parameters.resource_suffix }
    templateId     = { value = local.parameters.template_id }
    tenantId       = { value = local.parameters.tenant_id }
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

  final_params = merge(local.base_params, local.optional_params)
}

# Input variables
variable "root_management_group_id" {
  description = "Root management group ID (use tenant root MG for tenant-level templates)"
  type        = string
  default     = ""
}

# Backward-compatible alias (deprecated): use root_management_group_id instead
variable "management_group" {
  description = "[Deprecated] Use root_management_group_id. If set, used as fallback."
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

# Optional: enforce preflight permission checks (default: true)
variable "preflight_enabled" {
  description = "Run permission preflight checks before deployment"
  type        = bool
  default     = true
}

# Optional: let Terraform grant current principal Contributor at MG scope
variable "grant_self_mg_contributor" {
  description = "If true, Terraform assigns the current principal Contributor at the management group scope before deployment"
  type        = bool
  default     = false
}

# Data sources
data "azurerm_subscription" "main" {
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}

# Get Microsoft Graph service principal
data "azuread_service_principal" "graph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# Preflight moved into bootstrap; enforce via lifecycle below

# Create resource group for onboarding
resource "azurerm_resource_group" "onboarding" {
  name     = local.onboarding_resource_group_name
  location = var.location

  tags = local.tags
}

# Create user-assigned managed identity
resource "azurerm_user_assigned_identity" "cortex" {
  name                = local.identity_name
  resource_group_name = azurerm_resource_group.onboarding.name
  location            = azurerm_resource_group.onboarding.location

  tags = local.tags
}

# Create custom role definition at management group scope
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

# Assign custom role to managed identity
resource "azurerm_role_assignment" "cortex_mi_role_assignment" {
  scope              = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  role_definition_id = azurerm_role_definition.cortex_mi_role.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.cortex.principal_id

  depends_on = [
    azurerm_role_definition.cortex_mi_role,
    azurerm_user_assigned_identity.cortex
  ]
}


# Grant Microsoft Graph API permissions to customer object
resource "azuread_app_role_assignment" "graph_roles" {
  for_each = toset(local.graph_roles)

  app_role_id         = each.value
  principal_object_id = local.parameters.customer_object_id
  resource_object_id  = data.azuread_service_principal.graph.object_id
}

# Deploy ARM template at management group scope
resource "azurerm_management_group_template_deployment" "cortex_policy" {
  name                = "cortex-policy-${local.parameters.resource_suffix}"
  management_group_id = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"
  location            = var.location

  template_content = file(local.template_path)

  parameters_content = jsonencode(local.final_params)

  lifecycle {
    precondition {
      condition     = length(local.template_candidates) == 1
      error_message = "Expected exactly one template.json in the current directory."
    }
    precondition {
      condition     = length(local.target_mg) > 0
      error_message = "You must set root_management_group_id (or legacy management_group) to a non-empty value."
    }
    precondition {
      condition     = var.preflight_enabled ? try(data.external.bootstrap.result.preflight_ok == "true", true) : true
      error_message = "Preflight failed: ${try(data.external.bootstrap.result.preflight_error, "unknown error")}"
    }
  }

  depends_on = [
    azurerm_user_assigned_identity.cortex,
    azurerm_role_definition.cortex_mi_role,
    azurerm_role_assignment.cortex_mi_role_assignment
  ]
}

# Same-run cleanup of temporary MG Contributor assignment (if any)
resource "null_resource" "cleanup_temp_mg_contributor" {
  count = var.grant_self_mg_contributor && try(data.external.bootstrap.result.cleanup_cmd != "", false) ? 1 : 0

  provisioner "local-exec" {
    command     = data.external.bootstrap.result.cleanup_cmd
    interpreter = ["/bin/bash", "-lc"]
  }

  depends_on = [
    azurerm_management_group_template_deployment.cortex_policy
  ]
}

# Parse deployment outputs to get policy assignment name
locals {
  deployment_outputs = jsondecode(azurerm_management_group_template_deployment.cortex_policy.output_content)
  policy_assignment_name = local.deployment_outputs.created.value.policyAssignmentName
}

# Create policy remediation
resource "azapi_resource" "cortex_remediation" {
  type      = "Microsoft.PolicyInsights/remediations@2021-10-01"
  name      = "cortex-remediation-${local.parameters.resource_suffix}-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  parent_id = "/providers/Microsoft.Management/managementGroups/${local.target_mg}"

  body = jsonencode({
    properties = {
      policyAssignmentId = "/providers/Microsoft.Management/managementGroups/${local.target_mg}/providers/Microsoft.Authorization/policyAssignments/${local.policy_assignment_name}"
    }
  })

  depends_on = [
    azurerm_management_group_template_deployment.cortex_policy
  ]
}

# Outputs
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
  value       = azapi_resource.cortex_remediation.name
}
