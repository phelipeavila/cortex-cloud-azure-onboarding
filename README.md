# Terraform Onboarding Guide

## Overview
This directory contains the Terraform-based replacement for the `onboard.sh` automation. The conversion preserves the original provisioning flow while making it declarative and repeatable. It works for both tenant-level and management-group onboarding. Two files coordinate the onboarding process:

* `main.tf` – Terraform configuration that provisions Azure resources, assigns Microsoft Graph roles, and deploys the ARM template (or Bicep template compiled to ARM) at management-group scope.
* `bootstrap.sh` – A companion script invoked via Terraform's `external` data source to read `parameters.sh` without modification and to run preflight permission checks before any infrastructure change occurs.

## Mapping from `onboard.sh`
The table below shows how major blocks of the original bash script were ported to Terraform.

| Original step in `onboard.sh` | Terraform / bootstrap equivalent |
| --- | --- |
| Source `parameters.sh` and prompt for management group, subscription, location | `bootstrap.sh` sources `parameters.sh` directly. Variables `root_management_group_id`, `subscription_id`, and `location` replace interactive prompts. |
| Create onboarding resource group | `azurerm_resource_group.onboarding` resource block in `main.tf` |
| Create user-assigned managed identity | `azurerm_user_assigned_identity.cortex` |
| Define custom management-group role and assign to identity | `azurerm_role_definition.cortex_mi_role` and `azurerm_role_assignment.cortex_mi_role_assignment` |
| Assign Graph API application roles to the customer object | `azuread_app_role_assignment.graph_roles` for_each loop |
| Deploy `template.json` at management-group scope | `azurerm_management_group_template_deployment.cortex_policy` |
| Poll for policy outputs and trigger remediation | `local.deployment_outputs` reads deployment outputs and `azapi_resource.cortex_remediation` creates the remediation task |
| Ad-hoc permission checks sprinkled throughout | `bootstrap.sh` centralizes them using Azure CLI before Terraform touches Azure resources |

The resulting Terraform files can be used as-is across management groups because the logic that previously relied on bash loops and conditional branches is now expressed through Terraform expressions and locals.

## How `bootstrap.sh` Works
`bootstrap.sh` is executed through `data "external" "bootstrap"`. It performs three jobs:

1. **Load parameters** – It sources `parameters.sh` and emits a JSON map that Terraform can consume. Strings that represent JSON (for example `tags` and `template_version`) are normalized so Terraform can `jsondecode` them later.
2. **Preflight validation** – It verifies that:
   * `az account show` succeeds (you are logged in).
   * The signed-in principal has one of `Owner`, `User Access Administrator`, or `Contributor` on the target management group.
   * The same principal has `Owner` or `Contributor` on the subscription that will host the onboarding resources.
   * The account holds a directory role capable of assigning Graph app roles (Application Administrator, Cloud Application Administrator, Privileged Role Administrator, or Global Administrator).
3. **Automatic grant & cleanup (optional)** – If `grant_self_mg_contributor=true`, the script can temporarily grant the current principal `Contributor` at the management group scope when it detects a deficiency. The grant is recorded in `.mg_contributor_assign_id` so Terraform can remove it in the same run via `null_resource.cleanup_temp_mg_contributor` once preflight passes.

The script returns `preflight_ok` and `preflight_error` fields. Terraform guards the management-group deployment with a `lifecycle.precondition`; if preflight fails, the apply stops immediately with the descriptive error coming from `bootstrap.sh`.

## Key Sections in `main.tf`
* **Locals** – Read `graphAPIRoles.json`, decode values emitted by `bootstrap.sh`, compute resource names, and dynamically build the ARM template parameter map by inspecting whichever `template.json` is present.
* **Resource creation** – Mirrors the actions from `onboard.sh` for the resource group, managed identity, role definition, role assignment, Microsoft Graph role assignments, and deployment.
* **Template deployment guard** – Uses `lifecycle.precondition` to require a single `template.json`, a non-empty management group ID, and successful preflight.
* **Same-run cleanup** – `null_resource.cleanup_temp_mg_contributor` executes the command returned by `bootstrap.sh` to delete any temporary role assignment after the deployment succeeds.

## Using the Terraform Workflow
1. Ensure Azure CLI is installed and logged in (`az login`).
2. Copy `parameters.sh`, `graphAPIRoles.json`, `template.json`, `bootstrap.sh`, and `main.tf` into the working directory (along with optional `terraform.auto.tfvars`).
3. Set the required Terraform variables (for example in `terraform.auto.tfvars`). `root_management_group_id` can be either the tenant ID (for tenant-wide deployments) or the target management group ID:
   ```hcl
   root_management_group_id = "<tenant-id-or-management-group-id>"
   subscription_id          = "<subscription-guid>"
   location                 = "eastus"
   grant_self_mg_contributor = true   # optional
   preflight_enabled         = true   # default
   ```
4. Run `terraform init` and `terraform apply`.
5. If preflight grants temporary Contributor access, follow the script guidance: run `az account clear && az login --use-device-code`, then re-run `terraform apply`. The cleanup step runs automatically after a successful deploy.

## Relationship to `onboard.sh`
Because the conversion was disciplined, you can still diff the original `onboard.sh` against `main.tf` to find where each section moved. All Azure CLI invocations that mutated infrastructure have been replaced with Terraform resources. Operational logic (permission checks, parameter parsing) lives inside `bootstrap.sh`, which mirrors the procedural portions of the bash script. The Terraform code focuses solely on declarative infrastructure—matching the responsibilities split that `onboard.sh` previously mixed in a single script.

