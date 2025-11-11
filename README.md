# Terraform Onboarding Guide

## Overview
This directory contains the Terraform-based replacement for the `onboard.sh` automation. The conversion preserves the original provisioning flow while making it declarative and repeatable. It works for both tenant-level and management-group onboarding: supply the tenant root ID or the specific management group ID through Terraform variables. This Terraform-based flow also resolves the long-standing limitation of running `onboard.sh` in Azure Cloud Shell: the original script depended on direct Microsoft Graph API calls, which Microsoft blocks in Cloud Shell. By leveraging the AzureAD and MS Graph providers, Terraform performs those assignments without requiring unsupported manual Graph CLI calls. Two files coordinate the onboarding process:

* `main.tf` – Terraform configuration that provisions Azure resources, assigns Microsoft Graph roles, and deploys the ARM template (or Bicep template compiled to ARM) at management-group scope.
* `bootstrap.sh` – A companion script invoked via Terraform's `external` data source to read `parameters.sh` without modification and to run preflight permission checks before any infrastructure change occurs.

## Mapping from `onboard.sh`
The table below shows how major blocks of the original bash script were ported to Terraform.

| Original step in `onboard.sh` | Terraform / bootstrap equivalent |
| --- | --- |
| Source `parameters.sh` and prompt for management group, subscription, location | `bootstrap.sh` sources `parameters.sh` directly. Variables `tenant_id` or `management_group_id`, `subscription_id`, and `location` replace interactive prompts. |
| Create onboarding resource group | `azurerm_resource_group.onboarding` resource block in `main.tf` |
| Create user-assigned managed identity | `azurerm_user_assigned_identity.cortex` |
| Define custom management-group role and assign to identity | `azurerm_role_definition.cortex_mi_role` and `azurerm_role_assignment.cortex_mi_role_assignment` |
| Assign Graph API application roles to the customer object | `azuread_app_role_assignment.graph_roles` for_each loop |
| Deploy `template.json` at management-group scope | `azurerm_management_group_template_deployment.cortex_policy` |
| Poll for policy outputs and trigger remediation | `local.deployment_outputs` reads deployment outputs and `azapi_resource.cortex_remediation` creates the remediation task |
| Ad-hoc permission checks sprinkled throughout | `bootstrap.sh` centralizes them using Azure CLI before Terraform touches Azure resources |

The resulting Terraform files can be used as-is across management groups because the logic that previously relied on bash loops and conditional branches is now expressed through Terraform expressions and locals.

## How `bootstrap.sh` Works
`bootstrap.sh` is executed through `data "external" "bootstrap"`. It performs three main jobs:

1. **Load parameters** – It sources `parameters.sh` and emits a JSON map that Terraform can consume. Strings that represent JSON (for example `tags` and `template_version`) are normalized so Terraform can `jsondecode` them later.

2. **Auto-detect audit logs** – Examines the `template_version` variable to detect if audit logs are enabled by checking for any key starting with `AUDIT_LOGS-`. This information is automatically passed to the preflight script.

3. **Preflight validation** – When `preflight_enabled=true` (default), it downloads and runs the official preflight check script from the [cc-permissions-preflight repository](https://github.com/PaloAltoNetworks/cc-permissions-preflight). The script version is pinned in `PREFLIGHT_SCRIPT_VERSION` for production stability. The script validates all required permissions for onboarding:
   * For tenant-level onboarding: runs `azure-tenant` checks with audit logs flag
   * For management group-level onboarding: runs `azure-mg` checks with management group ID and audit logs flag
   
   All preflight output is captured and available in Terraform outputs for debugging and audit purposes.

The script returns `preflight_ok`, `preflight_error`, and `preflight_output` fields. Terraform guards the management-group deployment with a `lifecycle.precondition`; if preflight fails, the apply stops immediately with the descriptive error from `bootstrap.sh`.

## Key Sections in `main.tf`
* **Locals** – Read `graphAPIRoles.json`, decode values emitted by `bootstrap.sh`, compute resource names, validate that only one of `tenant_id` or `management_group_id` is provided, and dynamically build the ARM template parameter map by inspecting whichever `template.json` is present.
* **Resource creation** – Mirrors the actions from `onboard.sh` for the resource group, managed identity, role definition, role assignment, Microsoft Graph role assignments, and deployment.
* **Template deployment guard** – Uses `lifecycle.precondition` to require a single `template.json`, exactly one of `tenant_id` or `management_group_id` (not both), and successful preflight.

## Using the Terraform Workflow

1. Ensure Azure CLI is installed and logged in (`az login`).

2. Copy `parameters.sh`, `graphAPIRoles.json`, `template.json`, `bootstrap.sh`, and `main.tf` into the working directory (along with optional `terraform.auto.tfvars`).

3. **(Optional) Pin preflight script version** – Edit `bootstrap.sh` and update `PREFLIGHT_SCRIPT_VERSION` with a specific commit SHA for production stability. Default is a pinned commit. To update: visit https://github.com/PaloAltoNetworks/cc-permissions-preflight/commits/main

4. Set the required Terraform variables (for example in `terraform.auto.tfvars`). You must provide **exactly one** of `tenant_id` or `management_group_id`:
   
   **For tenant-level onboarding:**
   ```hcl
   tenant_id           = "<tenant-id>"
   subscription_id     = "<subscription-guid>"
   location            = "eastus"
   preflight_enabled   = true   # default
   ```
   
   **For management group-level onboarding:**
   ```hcl
   management_group_id = "<management-group-id>"
   subscription_id     = "<subscription-guid>"
   location            = "eastus"
   preflight_enabled   = true   # default
   ```
   
   See `terraform.auto.tfvars.example` for a complete example.

5. Run `terraform init` and `terraform apply`.

6. If preflight checks fail, the error message will include details from the preflight script output. Run the suggested commands to grant required permissions, then re-run `terraform apply`.

7. After successful deployment, view preflight results and configuration:
   ```bash
   terraform output preflight_status
   terraform output onboarding_configuration
   ```

## Terraform Outputs

After successful deployment, Terraform provides several useful outputs:

* **resource_group_name** – Name of the created onboarding resource group
* **managed_identity_name** – Name of the created managed identity
* **managed_identity_principal_id** – Principal ID of the managed identity
* **policy_assignment_name** – Name of the created policy assignment
* **remediation_name** – Name of the created remediation task
* **preflight_status** – Preflight check results including full output for debugging
* **onboarding_configuration** – Configuration details (onboarding type, target scope, etc.)

View outputs with: `terraform output` or `terraform output <output_name>`

## Preflight Script Version Control

The preflight script version is controlled in `bootstrap.sh` via the `PREFLIGHT_SCRIPT_VERSION` constant. By default, it's pinned to a specific commit for production stability. To update:

1. Visit: https://github.com/PaloAltoNetworks/cc-permissions-preflight/commits/main
2. Find the desired commit and copy its SHA
3. Edit `bootstrap.sh` line 9: `readonly PREFLIGHT_SCRIPT_VERSION="<commit-sha>"`
4. Commit the change to version control

Use `"main"` for the latest version (not recommended for production).

## Relationship to `onboard.sh`

Because the conversion was disciplined, you can still diff the original `onboard.sh` against `main.tf` to find where each section moved. All Azure CLI invocations that mutated infrastructure have been replaced with Terraform resources. Operational logic (permission checks, parameter parsing) lives inside `bootstrap.sh`, which mirrors the procedural portions of the bash script. The Terraform code focuses solely on declarative infrastructure—matching the responsibilities split that `onboard.sh` previously mixed in a single script.
