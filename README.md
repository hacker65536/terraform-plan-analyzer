# Terraform Plan Analyzer

A comprehensive analysis tool for Terraform Plan JSON files using jq. Provides detailed analysis capabilities for resource changes and output changes.

## Features

- **Resource Change Analysis**: Detection of create, update, delete, replace, forget, no-op actions
- **Output Change Analysis**: Track changes in output values
- **Import Detection**: Identify resource import operations
- **Multiple Output Formats**: Basic, short, detailed, and no-op only modes
- **Markdown Support**: Including GitHub comment optimization
- **Character Limit Check**: Character limit warnings for GitHub comments

## Basic Usage

### Generate Terraform Plan JSON File

```bash
# Generate Terraform plan file in JSON format
terraform plan -out=plan >/dev/null 2>&1
terraform show -json plan > plan.json
```

### Script Execution

```bash
# Basic analysis (default)
./terraform-plan-analyzer.sh plan.json

# Short display (diff format, excludes no-op)
./terraform-plan-analyzer.sh --short plan.json

# Detailed display (grouped by action type)
./terraform-plan-analyzer.sh --detail plan.json

# Show only no-op resources
./terraform-plan-analyzer.sh --no-op plan.json

# Output in Markdown format
./terraform-plan-analyzer.sh --markdown plan.json
./terraform-plan-analyzer.sh --short --markdown plan.json
./terraform-plan-analyzer.sh --detail --markdown plan.json

# GitHub comment optimization (with character limit check)
./terraform-plan-analyzer.sh --github-comment plan.json
```

## Options

| Option | Description |
|--------|-------------|
| `--short` | Display only changes in concise diff format |
| `--detail` | Display detailed breakdown grouped by action type |
| `--no-op` | Display only resources with no changes (no-op) |
| `--markdown` | Output in Markdown format |
| `--github-comment` | Optimize for GitHub comments (with character limit check) |
| `-h, --help` | Show help message |

## Output Examples

### Basic Mode (Default)
```
🔍 Terraform Plan Analysis for: plan.json
==============================================

📊 Change Actions Summary:
-------------------------
create: 5
update: 2
delete: 3

📊 Resource Types:
-----------------
  aws_s3_bucket: 3
  aws_iam_role: 2  
  aws_lambda_function: 2

📊 Plan Summary:
---------------
Terraform Version: 1.0.0
Total Resource Changes: 7
Applyable: true
```

### --short Mode
```
+ aws_s3_bucket.example
+ aws_s3_bucket.logs
~ aws_iam_role.lambda_role
~ aws_lambda_function.processor
- aws_s3_bucket.old_bucket
-/+ aws_lambda_function.migrated Import
+ output.bucket_name
```

### --detail Mode
```
📊 Resource Changes Detail:
===========================

📊 CREATE Actions:
==================
  - aws_s3_bucket.example
  - aws_s3_bucket.logs

📊 UPDATE Actions:
==================
  - aws_iam_role.lambda_role
  - aws_lambda_function.processor

📊 DELETE Actions:
==================
  - aws_s3_bucket.old_bucket

📊 REPLACE Actions:
===================
  - aws_lambda_function.migrated Import

📊 OUTPUT CREATE Actions:
=========================
  - bucket_name

📊 Summary:
  Resource Changes:
    create: 2
    update: 2
    delete: 1
    replace: 1
    importing: 1
  Output Changes:
    create: 1
```

### Markdown Mode
```markdown
# Terraform Plan Analysis

**File:** `plan.json`

## Change Actions Summary

- **create**: 2
- **update**: 2
- **delete**: 1
- **importing**: 1

## Resource Types

- **aws_lambda_function**: 2
- **aws_s3_bucket**: 2
- **aws_iam_role**: 1

## Plan Summary

- **Terraform Version**: 1.0.0
- **Total Resource Changes**: 5
- **Applyable**: true
```

## Useful jq Queries

### Basic Aggregation
```bash
# Count by action type
jq '[.resource_changes[].change.actions[]] | group_by(.) | map({action: .[0], count: length})' plan.json
```

### Practical Queries
```bash
# List resources to be deleted
jq '.resource_changes[] | select(.change.actions[] == "delete") | .address' plan.json

# List resources to be created
jq '.resource_changes[] | select(.change.actions[] == "create") | .address' plan.json

# List resources to be updated
jq '.resource_changes[] | select(.change.actions[] == "update") | .address' plan.json
```

## File Structure

```
├── README.md                   # This file
├── README_JP.md               # Japanese version
└── terraform-plan-analyzer.sh # Terraform Plan analysis script
```

## Action Types

| Symbol | Action | Description |
|--------|--------|-------------|
| `+` | create | Create new resource |
| `~` | update | Update existing resource |
| `-` | delete | Delete resource |
| `-/+` | replace | Replace resource (delete → create) |
| `#` | forget | Remove from management |
| (none) | no-op | No changes |

## Special Indicators

- `Import`: Resource with import operation
- `output.`: Output value changes

## Dependencies

- **jq**: Required for JSON processing. Installation commands:
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt-get install jq`
  - CentOS/RHEL: `sudo yum install jq`

---

**Note:** 
- The `--short` and `--detail` options hide `no-op` actions
- The `--github-comment` option checks the 65,536 character limit and displays warnings when exceeded
- The script automatically checks for jq availability and displays installation instructions when missing
