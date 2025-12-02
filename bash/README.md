# Azure Onboarding Scripts

This directory contains scripts to onboard Azure resources to Cortex.

## Prerequisites

Ensure the following files are present in the same directory:
- `parameters.sh`: Contains configuration variables (Tenant ID, Subscription ID, etc.).
- `graphAPIRoles.json`: Defines required Graph API roles.
- `template.json`: The Azure ARM template for policy deployment.

You must have the **Azure CLI** installed and authenticated:
```bash
az login
```

## Configuration

You can pre-fill required inputs in the `parameters.sh` file to avoid being prompted during execution. Uncomment and set the following variables at the end of the file:

```bash
# Optional: Pre-filled inputs for scripts
management_group="your-mg-id-or-tenant-id"
subscription_id="your-subscription-id"
location="eastus"
```

If provided, the scripts will prompt for confirmation (Press Enter to accept) rather than requiring manual entry.

## Usage

### Option A: Single Script (Recommended)

Run the consolidated script that performs all onboarding steps:

```bash
./onboard_new.sh
```

This script will:
1. Create the Resource Group for onboarding
2. Handle migration of resources if upgrading from a previous deployment
3. Grant Graph API permissions to the Enterprise Application
4. Create the User Assigned Managed Identity
5. Create and assign the custom Role for the Managed Identity
6. Deploy the Policy Definition and Assignment
7. Trigger remediation tasks and monitor compliance

### Option B: Step-by-Step (Modular)

Alternatively, you can run the onboarding in three separate steps:

#### Step 1: Preparation
```bash
./01_onboard_setup.sh
```
Creates the Resource Group and handles migration if necessary.

#### Step 2: Identity Setup
```bash
./02_onboard_identity.sh
```
Creates the Managed Identity and assigns permissions (RBAC and Graph API).

#### Step 3: Policy Deployment
```bash
./03_onboard_policy.sh
```
Deploys the Azure Policy and monitors compliance.

## Prompts

You will be prompted for (unless configured in `parameters.sh`):
- **Management Group ID**: The target management group scope (or Tenant ID).
- **Subscription ID**: The subscription where the Managed Identity will be created.
- **Location**: The Azure region (e.g., `eastus`).

## Script Details

| Script | Purpose |
|--------|---------|
| `onboard_new.sh` | All-in-one onboarding script (recommended) |
| `01_onboard_setup.sh` | Infrastructure setup (Resource Group, migration) |
| `02_onboard_identity.sh` | Identity setup (Managed Identity, roles, Graph API) |
| `03_onboard_policy.sh` | Policy deployment and remediation |
| `onboard.sh` | Original script (legacy) |

## Troubleshooting

See `IMPROVEMENTS.md` for details on error handling and Cloud Shell compatibility fixes in the new scripts.
