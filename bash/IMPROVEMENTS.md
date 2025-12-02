# Azure Onboarding Script: Improvements Overview

This document details the improvements made to the original `onboard.sh` script, resulting in the enhanced `onboard_new.sh`.

## 1. Enhanced User Experience

### Smart Input Handling
| Feature | Original (`onboard.sh`) | Improved (`onboard_new.sh`) |
|---------|-------------------------|------------------------------|
| Pre-fill support | ❌ Always prompts | ✅ Reads from `parameters.sh`, confirms if set |
| Input validation | ✅ Basic region check | ✅ Same + graceful error recovery |

### Visual Feedback
| Feature | Original | Improved |
|---------|----------|----------|
| Long-running commands | Silent (appears frozen) | ✅ Spinner animation (`\|/-\`) |
| Compliance evaluation | Repeated log lines | ✅ In-place progress updates with attempt counter |
| Remediation progress | Repeated log lines | ✅ In-place progress updates with attempt counter |

**Example output comparison:**

*Original:*
```
[INFO] 0 evalutated out of 1 subscriptions.
[INFO] 0 evalutated out of 1 subscriptions.
[INFO] 1 evalutated out of 1 subscriptions.
```

*Improved:*
```
[INFO] Waiting for compliance evaluation (checking every 20s)...
[INFO] This may take a few minutes while Azure evaluates policy compliance.

[INFO] Evaluation in progress... 1/1 subscriptions evaluated (attempt #3)
```

## 2. Robust Error Handling

### Fail-Safe Mechanisms
| Feature | Original | Improved |
|---------|----------|----------|
| Pipeline errors | Not caught | ✅ `set -o pipefail` catches failures |
| Variable quoting | Unquoted (breaks on spaces) | ✅ Properly quoted (`"$subscription_id"`) |
| Empty value checks | Basic | ✅ Defaults to 0 for compliance counts |

### Suppressed Expected Errors
Commands that may fail as part of normal operation no longer clutter the output:

| Command | Reason for Suppression |
|---------|------------------------|
| `az deployment mg show` | "DeploymentNotFound" is expected for new setups |
| `az group show` (previous RG) | Previous RG may not exist |
| `az resource list/move` | Migration may not be needed |
| `az identity delete` | Previous identity may not exist |
| `az role assignment create` | Transient "Principal not found" during AD propagation |
| `az policy state summarize` | May fail transiently during evaluation |
| `az policy remediation create` | May fail transiently |

## 3. Cloud Shell Compatibility

### Graph API Fix
| Issue | Original | Improved |
|-------|----------|----------|
| Token scope | Default audience (fails in Cloud Shell) | ✅ Explicit `--resource https://graph.microsoft.com` |
| Existing permissions | Attempts assignment anyway (errors) | ✅ Checks if permission exists first (idempotent) |
| Assignment failure | Script continues silently | ✅ Logs warning with manual instructions |

## 4. Technical Improvements

### JSON Handling
| Issue | Original | Improved |
|-------|----------|----------|
| Role definition creation | Inline JSON (breaks on special chars like parentheses) | ✅ Writes to temp file, uses `@/tmp/role_def.json` |

### Code Organization
| Aspect | Original | Improved |
|--------|----------|----------|
| Structure | Flat script | ✅ Clear section headers with comments |
| Comments | Minimal | ✅ Detailed explanations for each block |
| Helper functions | Basic `log()` and `retry()` | ✅ Added `spinner()`, `exec_with_spinner()`, `get_input()` |

## 5. Summary of Changes

| Category | Change |
|----------|--------|
| **UX** | Pre-fillable inputs, spinners, in-place progress updates |
| **Error Handling** | `pipefail`, quoted variables, suppressed expected errors, default values |
| **Cloud Shell** | Graph API token fix, idempotent permission checks |
| **Robustness** | Temp file for JSON, proper exit codes |
| **Documentation** | Section headers, inline comments |

## 6. Files

| File | Purpose |
|------|---------|
| `onboard.sh` | Original monolithic script |
| `onboard_new.sh` | Improved script with all enhancements |
| `parameters.sh` | Configuration file (supports pre-filled inputs) |
| `graphAPIRoles.json` | Graph API role IDs to assign |
| `template.json` | ARM template for policy deployment |
