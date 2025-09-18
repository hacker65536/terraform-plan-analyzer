#!/usr/bin/env bash

# =============================================================================
# Terraform Plan JSON Analysis Script using jq
# 
# This script analyzes Terraform plan JSON files and provides various output
# formats including short, detailed, and basic analysis modes.
# =============================================================================

# =============================================================================
# CONSTANTS
# =============================================================================

readonly GITHUB_COMMENT_LIMIT="${TERRAFORM_ANALYZER_GITHUB_LIMIT:-65536}"
readonly DEFAULT_MODE="${TERRAFORM_ANALYZER_DEFAULT_MODE:-basic}"

# =============================================================================
# GLOBAL VARIABLES FOR CACHING
# =============================================================================

declare -A resource_counts
declare -A output_counts
declare -g importing_count_cached=""
declare -g cache_initialized="false"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if jq command is available
check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found. Please install jq to use this script."
        echo "Install jq using:"
        echo "  - macOS: brew install jq"
        echo "  - Ubuntu/Debian: sudo apt-get install jq"
        echo "  - CentOS/RHEL: sudo yum install jq"
        exit 1
    fi
}

# Show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <tfplan.json>

DESCRIPTION:
    Analyze Terraform plan JSON files and display changes in various formats.

OPTIONS:
    --short      Show only changed resources and outputs (compact format)
    --detail     Show detailed changes grouped by action type
    --no-op      Show only resources with no changes
    --markdown   Output in markdown format
    --github-comment  Optimize output for GitHub comments (with character limit check)
    -h, --help   Show this help message

MODES:
    (default)    Show basic analysis with summary statistics
    --short      Compact diff-style output showing all changes
    --detail     Comprehensive breakdown by action types
    --no-op      Focus on resources that won't change

EXAMPLES:
    $0 plan.json                    # Basic analysis
    $0 --short plan.json           # Compact change list
    $0 --detail --markdown plan.json  # Detailed markdown report
    $0 --no-op plan.json           # Show no-op resources only

EOF
}

# Initialize cache with all counts in a single jq execution
initialize_cache() {
    local file="$1"
    
    if [[ "$cache_initialized" == "true" ]]; then
        return 0
    fi
    
    # Single jq execution to get all counts
    local cache_data
    if ! cache_data=$(jq -r '
        def count_by_action(action):
            if action == "create" then
                [(.resource_changes // [])[] | select(.change.actions == ["create"])] | length
            elif action == "update" then
                [(.resource_changes // [])[] | select(.change.actions == ["update"] and (.change.importing // false | not))] | length
            elif action == "update-import" then
                [(.resource_changes // [])[] | select(.change.actions == ["update"] and (.change.importing // false))] | length
            elif action == "delete" then
                [(.resource_changes // [])[] | select(.change.actions == ["delete"])] | length
            elif action == "replace" then
                [(.resource_changes // [])[] | select(.change.actions | contains(["create"]) and contains(["delete"])) | select(has("action_reason")) | select(.action_reason == "replace_because_cannot_update") | select((.change.importing // false | . == false))] | length
            elif action == "replace-import" then
                [(.resource_changes // [])[] | select(.change.actions | contains(["create"]) and contains(["delete"])) | select(has("action_reason")) | select(.action_reason == "replace_because_cannot_update") | select((.change.importing // false | . != false))] | length
            elif action == "import-nochange" then
                [(.resource_changes // [])[] | select(.change.actions == ["no-op"] and (.change.importing // false))] | length
            elif action == "remove-forget" then
                [(.resource_changes // [])[] | select(.change.actions == ["forget"])] | length
            elif action == "no-op" then
                [(.resource_changes // [])[] | select(.change.actions == ["no-op"] and (.change.importing // false | not))] | length
            else
                0
            end;
        
        def count_output_by_action(action):
            if action == "create" then
                [.output_changes // {} | to_entries[] | select(.value.actions == ["create"])] | length
            elif action == "update" then
                [.output_changes // {} | to_entries[] | select(.value.actions == ["update"])] | length
            elif action == "delete" then
                [.output_changes // {} | to_entries[] | select(.value.actions == ["delete"])] | length
            elif action == "no-op" then
                [.output_changes // {} | to_entries[] | select(.value.actions == ["no-op"])] | length
            else
                0
            end;
        
        {
            "resource_create": count_by_action("create"),
            "resource_update": count_by_action("update"),
            "resource_update_import": count_by_action("update-import"),
            "resource_delete": count_by_action("delete"),
            "resource_replace": count_by_action("replace"),
            "resource_replace_import": count_by_action("replace-import"),
            "resource_import_nochange": count_by_action("import-nochange"),
            "resource_remove_forget": count_by_action("remove-forget"),
            "resource_no_op": count_by_action("no-op"),
            "output_create": count_output_by_action("create"),
            "output_update": count_output_by_action("update"),
            "output_delete": count_output_by_action("delete"),
            "output_no_op": count_output_by_action("no-op"),
            "importing_total": [(.resource_changes // [])[] | select(.change.importing // false)] | length
        }
    ' "$file" 2>/dev/null) || [[ -z "$cache_data" ]]; then
        echo "Error: Failed to parse JSON file or execute jq query" >&2
        exit 1
    fi
    
    # Parse the JSON result and populate associative arrays
    eval "$(echo "$cache_data" | jq -r '
        to_entries[] | 
        if (.key | startswith("resource_")) then
            "resource_counts[\"" + (.key | sub("resource_"; "")) + "\"]=" + (.value | tostring)
        elif (.key | startswith("output_")) then
            "output_counts[\"" + (.key | sub("output_"; "")) + "\"]=" + (.value | tostring)
        elif .key == "importing_total" then
            "importing_count_cached=" + (.value | tostring)
        else
            empty
        end
    ')"
    
    cache_initialized="true"
}

# =============================================================================
# RESOURCE ANALYSIS FUNCTIONS
# =============================================================================

# Build jq filter for resource actions
build_resource_filter() {
    local action="$1"
    
    case "$action" in
        "create")
            echo 'select(.change.actions == ["create"])'
            ;;
        "update")
            echo 'select(.change.actions == ["update"] and (.change.importing // false | not))'
            ;;
        "update-import")
            echo 'select(.change.actions == ["update"] and (.change.importing // false))'
            ;;
        "delete")
            echo 'select(.change.actions == ["delete"])'
            ;;
        "replace")
            echo 'select(.change.actions | contains(["create"]) and contains(["delete"])) | select(has("action_reason")) | select(.action_reason == "replace_because_cannot_update") | select((.change.importing // false | . == false))'
            ;;
        "replace-import")
            echo 'select(.change.actions | contains(["create"]) and contains(["delete"])) | select(has("action_reason")) | select(.action_reason == "replace_because_cannot_update") | select((.change.importing // false | . != false))'
            ;;
        "import-nochange")
            echo 'select(.change.actions == ["no-op"] and (.change.importing // false))'
            ;;
        "remove-forget")
            echo 'select(.change.actions == ["forget"])'
            ;;
        "no-op")
            echo 'select(.change.actions == ["no-op"] and (.change.importing // false | not))'
            ;;
    esac
}

# Get resources filtered by action type
get_resources_by_action() {
    local action="$1"
    local file="$2"
    local filter
    filter=$(build_resource_filter "$action")
    
    jq -r "(.resource_changes // [])[] | $filter | {address: .address, importing: (.change.importing // false)}" "$file" 2>/dev/null
}

# Count resources by action type (using cache)
count_resources_by_action() {
    local action="$1"
    local file="$2"
    
    initialize_cache "$file"
    
    # Convert action name to match cache key format
    local cache_key
    case "$action" in
        "update-import") cache_key="update_import" ;;
        "replace-import") cache_key="replace_import" ;;
        "import-nochange") cache_key="import_nochange" ;;
        "remove-forget") cache_key="remove_forget" ;;
        "no-op") cache_key="no_op" ;;
        *) cache_key="$action" ;;
    esac
    
    echo "${resource_counts[$cache_key]:-0}"
}

# =============================================================================
# OUTPUT CHANGES ANALYSIS FUNCTIONS
# =============================================================================

# Build jq filter for output actions
build_output_filter() {
    local action="$1"
    
    case "$action" in
        "create")
            echo 'select(.value.actions == ["create"])'
            ;;
        "update")
            echo 'select(.value.actions == ["update"])'
            ;;
        "delete")
            echo 'select(.value.actions == ["delete"])'
            ;;
        "no-op")
            echo 'select(.value.actions == ["no-op"])'
            ;;
        *)
            echo "select(.value.actions | contains([\"$action\"]))"
            ;;
    esac
}

# Get output changes filtered by action type
get_output_changes_by_action() {
    local action="$1"
    local file="$2"
    local filter
    filter=$(build_output_filter "$action")
    
    jq -r ".output_changes // {} | to_entries[] | $filter | {name: .key, actions: .value.actions}" "$file" 2>/dev/null
}

# Count output changes by action type (using cache)
count_output_changes_by_action() {
    local action="$1"
    local file="$2"
    
    initialize_cache "$file"
    
    # Convert action name to match cache key format
    local cache_key
    case "$action" in
        "no-op") cache_key="no_op" ;;
        *) cache_key="$action" ;;
    esac
    
    echo "${output_counts[$cache_key]:-0}"
}

# =============================================================================
# CHANGE DETECTION FUNCTIONS
# =============================================================================

# Count importing resources (using cache)
count_importing_resources() {
    local file="$1"
    initialize_cache "$file"
    echo "$importing_count_cached"
}

# Check if there are any resource changes (excluding no-op)
has_resource_changes() {
    local file="$1"
    initialize_cache "$file"
    
    local total_changes=0
    for action in create update update_import delete replace replace_import import_nochange remove_forget; do
        total_changes=$((total_changes + ${resource_counts[$action]:-0}))
    done
    
    [ "$total_changes" -gt 0 ]
}

# Check if there are any output changes (excluding no-op)
has_output_changes() {
    local file="$1"
    initialize_cache "$file"
    
    local total_changes=0
    for action in create update delete; do
        total_changes=$((total_changes + ${output_counts[$action]:-0}))
    done
    
    [ "$total_changes" -gt 0 ]
}

# Check if there are any changes at all (resources or outputs)
has_any_changes() {
    local file="$1"
    has_resource_changes "$file" || has_output_changes "$file"
}

# =============================================================================
# DISPLAY FUNCTIONS - SECTIONS
# =============================================================================

# Calculate separator length for action headers
get_separator_length() {
    local action="$1"
    local base_length=17
    
    case "$action" in
        "replace") echo $((base_length + 1)) ;;
        "no-op") echo $((base_length - 2)) ;;
        *) echo $base_length ;;
    esac
}

# Generate separator string efficiently
generate_separator() {
    local length="$1"
    printf '=%.0s' $(seq 1 "$length")
}

# Format resource item display
format_resource_item() {
    local action="$1"
    local prefix="$2"
    
    # All actions use the same format for detail display
    echo ". as \$item | \"$prefix\" + \$item.address + (if \$item.importing then \" Import\" else \"\" end)"
}

# Display a resource action section with proper formatting
show_resource_action_section() {
    local action="$1"
    local file="$2"
    local markdown="$3"
    local action_upper
    action_upper=$(echo "$action" | tr '[:lower:]' '[:upper:]')
    
    local resource_count
    resource_count=$(count_resources_by_action "$action" "$file")
    if [ "$resource_count" -gt 0 ]; then
        echo ""
        
        if [ "$markdown" = "true" ]; then
            echo "### $action_upper Actions"
            echo ""
            local format_expr
            format_expr=$(format_resource_item "$action" "- ")
            get_resources_by_action "$action" "$file" | jq -r "$format_expr"
        else
            echo "📊 $action_upper Actions:"
            
            local separator_length
            separator_length=$(get_separator_length "$action")
            generate_separator "$separator_length"
            echo ""
            
            local format_expr
            format_expr=$(format_resource_item "$action" "  - ")
            get_resources_by_action "$action" "$file" | jq -r "$format_expr"
        fi
    fi
}

# Calculate separator length for output action headers
get_output_separator_length() {
    local action="$1"
    local base_length=24
    
    case "$action" in
        "no-op") echo $((base_length - 2)) ;;
        *) echo $base_length ;;
    esac
}

# Display an output changes section with proper formatting
show_output_changes_section() {
    local action="$1"
    local file="$2"
    local markdown="$3"
    local action_upper
    action_upper=$(echo "$action" | tr '[:lower:]' '[:upper:]')
    
    local output_count
    output_count=$(count_output_changes_by_action "$action" "$file")
    if [ "$output_count" -gt 0 ]; then
        echo ""
        
        if [ "$markdown" = "true" ]; then
            echo "### OUTPUT $action_upper Actions"
            echo ""
            get_output_changes_by_action "$action" "$file" | jq -r '. as $item | "- " + $item.name'
        else
            echo "📊 OUTPUT $action_upper Actions:"
            
            local separator_length
            separator_length=$(get_output_separator_length "$action")
            generate_separator "$separator_length"
            echo ""
            
            get_output_changes_by_action "$action" "$file" | jq -r '. as $item | "  - " + $item.name'
        fi
    fi
}

# =============================================================================
# DISPLAY FUNCTIONS - OUTPUT FORMATS
# =============================================================================

# Generate compact diff-style output showing all changes
generate_short_output() {
    local file="$1"
    
    # Show resource changes with appropriate symbols
    jq -r '(.resource_changes // [])[] | 
           select((.change.actions | map(. != "no-op") | any) or (.change.importing // false)) | 
           if (.change.actions == ["delete", "create"]) then 
               "-/+ " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions == ["create", "delete"]) then 
               "+/- " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions | contains(["create"])) then 
               "+ " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions | contains(["update"])) then 
               "~ " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions | contains(["delete"])) then 
               "- " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions | contains(["forget"])) then 
               "# " + .address + (if .change.importing then " Import" else "" end)
           elif (.change.actions == ["no-op"] and (.change.importing // false)) then 
               "= " + .address 
           else empty end' "$file" 2>/dev/null
    
    # Show output changes with appropriate symbols
    jq -r '.output_changes // {} | 
           to_entries[] | 
           select(.value.actions | map(. != "no-op") | any) | 
           if (.value.actions | contains(["create"])) then 
               "+ output." + .key
           elif (.value.actions | contains(["update"])) then 
               "~ output." + .key
           elif (.value.actions | contains(["delete"])) then 
               "- output." + .key
           else empty end' "$file" 2>/dev/null
}

# Show "No changes" message when there are no modifications
show_no_changes() {
    local markdown="$1"
    
    if [ "$markdown" = "true" ]; then
        cat << EOF
# No Changes

✅ **No changes detected**

All resources and outputs are up-to-date and no actions need to be performed.
EOF
    else
        cat << EOF
✅ No Changes
==============
All resources and outputs are up-to-date and no actions need to be performed.
EOF
    fi
}

# Show detailed breakdown of all changes grouped by action type
show_detail_output() {
    local file="$1"
    local markdown="$2"
    
    # Header
    if [ "$markdown" = "true" ]; then
        echo "# Analyze Terraform Plan"
        echo ""
        echo "## Resource Changes Detail"
        echo ""
    else
        echo "📊 Resource Changes Detail:"
        echo "==========================="
    fi
    
    # Process each resource action type in logical order
    local detail_actions=("create" "update" "update-import" "delete" "import-nochange" "remove-forget")
    for action in "${detail_actions[@]}"; do
        show_resource_action_section "$action" "$file" "$markdown"
    done
    
    # Handle replace and replace-import actions using the standardized functions
    show_resource_action_section "replace" "$file" "$markdown"
    show_resource_action_section "replace-import" "$file" "$markdown"
    
    # Process output changes if they exist
    if has_output_changes "$file"; then
        echo ""
        if [ "$markdown" = "true" ]; then
            echo "## Output Changes Detail"
            echo ""
        else
            echo "📊 Output Changes Detail:"
            echo "========================"
        fi
        
        local output_detail_actions=("create" "update" "delete")
        for action in "${output_detail_actions[@]}"; do
            show_output_changes_section "$action" "$file" "$markdown"
        done
    fi
    
    # Summary section
    echo ""
    if [ "$markdown" = "true" ]; then
        echo "## Summary"
        echo ""
    else
        echo "📊 Summary:"
    fi
    generate_summary "$file" "$markdown"
}

# Show resources that have no changes (no-op only)
show_no_op_output() {
    local file="$1"
    local markdown="$2"
    
    if [ "$markdown" = "true" ]; then
        cat << EOF
# No-Op Resources

Resources with no changes:

EOF
        show_resource_action_section "no-op" "$file" "$markdown"
    else
        cat << EOF
📊 No-Op Resources
==================
Resources with no changes:
EOF
        show_resource_action_section "no-op" "$file" "$markdown"
    fi
}

# Show basic analysis with summary statistics and overview
show_basic_output() {
    local file="$1"
    local markdown="$2"
    
    if [ "$markdown" = "true" ]; then
        cat << EOF
# Terraform Plan Analysis

**File:** \`$file\`

## Change Actions Summary

EOF
        jq -r '[(.resource_changes // [])[].change.actions[]] | 
               group_by(.) | 
               map({action: .[0], count: length}) | 
               sort_by(if .action == "create" then 1 
                       elif .action == "update" then 2 
                       elif .action == "delete" then 3 
                       elif .action == "no-op" then 4 
                       else 5 end) | 
               map("- **\(.action)**: \(.count)") | 
               .[]' "$file" 2>/dev/null
        
        # Add importing count if there are any
        local importing_count
        importing_count=$(count_importing_resources "$file")
        if [ -n "$importing_count" ] && [ "$importing_count" -gt 0 ]; then
            echo "- **importing**: $importing_count"
        fi
        
        cat << EOF

## Resource Types

EOF
        jq -r '(.resource_changes // []) | 
               group_by(.type) | 
               map("- **\(.[0].type)**: \(length)") | 
               sort | 
               .[]' "$file" 2>/dev/null
        
        cat << EOF

## Plan Summary

EOF
        jq -r '"- **Terraform Version**: \(.terraform_version)\n- **Total Resource Changes**: \((.resource_changes // []) | length)\n- **Applyable**: \(.applyable)"' "$file" 2>/dev/null
    else
        echo "🔍 Terraform Plan Analysis for: $file"
        echo "=============================================="

        echo ""
        echo "📊 Change Actions Summary:"
        echo "-------------------------"
        jq -r '[(.resource_changes // [])[].change.actions[]] | 
               group_by(.) | 
               map({action: .[0], count: length}) | 
               sort_by(if .action == "create" then 1 
                       elif .action == "update" then 2 
                       elif .action == "delete" then 3 
                       elif .action == "no-op" then 4 
                       else 5 end) | 
               map("\(.action): \(.count)") | 
               .[]' "$file" 2>/dev/null
        
        # Add importing count if there are any
        local importing_count
        importing_count=$(count_importing_resources "$file")
        if [ -n "$importing_count" ] && [ "$importing_count" -gt 0 ]; then
            echo "importing: $importing_count"
        fi

        echo ""
        echo "📊 Resource Types:"
        echo "-----------------"
        jq -r '(.resource_changes // []) | 
               group_by(.type) | 
               map("  \(.[0].type): \(length)") | 
               sort | 
               .[]' "$file" 2>/dev/null

        echo ""
        echo "📊 Plan Summary:"
        echo "---------------"
        jq -r '"Terraform Version: \(.terraform_version)
Total Resource Changes: \((.resource_changes // []) | length)
Applyable: \(.applyable)"' "$file" 2>/dev/null
    fi
}

# Generate summary of resource actions (used in detail mode)
generate_summary() {
    local file="$1"
    local markdown="$2"
    
    if [ "$markdown" = "true" ]; then
        echo "### Resource Changes Summary"
        echo ""
        jq -r '[(.resource_changes // [])[].change.actions[]] | 
               map(select(. != "no-op")) | 
               group_by(.) | 
               map({action: .[0], count: length}) | 
               sort_by(if .action == "create" then 1 
                       elif .action == "update" then 2 
                       elif .action == "delete" then 3 
                       elif .action == "forget" then 4 
                       else 5 end) | 
               map("- **\(.action)**: \(.count)") | 
               .[]' "$file" 2>/dev/null
        
        # Add importing count if there are any
        local importing_count
        importing_count=$(count_importing_resources "$file")
        if [ -n "$importing_count" ] && [ "$importing_count" -gt 0 ]; then
            echo "- **importing**: $importing_count"
        fi
        
        # Add output changes summary if there are any
        if has_output_changes "$file"; then
            echo ""
            echo "### Output Changes Summary"
            echo ""
            jq -r '[.output_changes // {} | to_entries[].value.actions[]] | 
                   map(select(. != "no-op")) | 
                   group_by(.) | 
                   map({action: .[0], count: length}) | 
                   sort_by(if .action == "create" then 1 
                           elif .action == "update" then 2 
                           elif .action == "delete" then 3 
                           else 5 end) | 
                   map("- **\(.action)**: \(.count)") | 
                   .[]' "$file" 2>/dev/null
        fi
    else
        echo "  Resource Changes:"
        jq -r '[(.resource_changes // [])[].change.actions[]] | 
               map(select(. != "no-op")) | 
               group_by(.) | 
               map({action: .[0], count: length}) | 
               sort_by(if .action == "create" then 1 
                       elif .action == "update" then 2 
                       elif .action == "delete" then 3 
                       elif .action == "forget" then 4 
                       else 5 end) | 
               map("    \(.action): \(.count)") | 
               .[]' "$file" 2>/dev/null
        
        # Add importing count if there are any
        local importing_count
        importing_count=$(count_importing_resources "$file")
        if [ -n "$importing_count" ] && [ "$importing_count" -gt 0 ]; then
            echo "    importing: $importing_count"
        fi
        
        # Add output changes summary if there are any
        if has_output_changes "$file"; then
            echo ""
            echo "  Output Changes:"
            jq -r '[.output_changes // {} | to_entries[].value.actions[]] | 
                   map(select(. != "no-op")) | 
                   group_by(.) | 
                   map({action: .[0], count: length}) | 
                   sort_by(if .action == "create" then 1 
                           elif .action == "update" then 2 
                           elif .action == "delete" then 3 
                           else 5 end) | 
                   map("    \(.action): \(.count)") | 
                   .[]' "$file" 2>/dev/null
        fi
    fi
}

# =============================================================================
# GITHUB COMMENT FUNCTIONS
# =============================================================================

# Check if output exceeds GitHub comment character limit
check_github_comment_limit() {
    local output="$1"
    local char_count=${#output}
    
    if [ "$char_count" -gt "$GITHUB_COMMENT_LIMIT" ]; then
        echo "⚠️  Warning: Output exceeds GitHub comment limit!"
        echo "   Character count: $char_count / $GITHUB_COMMENT_LIMIT"
        echo "   Consider using --short mode or reducing the scope of changes."
        echo ""
        return 1
    fi
    
    return 0
}

# =============================================================================
# OUTPUT GENERATION FUNCTION
# =============================================================================

# Unified function to generate output based on mode
show_changes_output() {
    local file="$1"
    local markdown="$2"
    local mode="$3"
    
    case "$mode" in
        "short")
            if has_any_changes "$file"; then
                if [ "$markdown" = "true" ]; then
                    echo "<details><summary>Short Result (Click me)</summary>"
                    echo "" 
                    echo "\`+\` create , \`~\` update , \`-\` delete , \`-/+\` replace(delete->create) , \`+/-\` replace(create->delete) , \`#\` remove , \`=\` import(no change)"
                    echo "\`\`\`hcl"
                    generate_short_output "$file"
                    echo "\`\`\`"
                    echo "</details>"
                else
                    generate_short_output "$file"
                fi
            else
                show_no_changes "$markdown"
            fi
            ;;
        "detail")
            if has_any_changes "$file"; then
                show_detail_output "$file" "$markdown"
            else
                show_no_changes "$markdown"
            fi
            ;;
        "no-op")
            show_no_op_output "$file" "$markdown"
            ;;
        "basic")
            if has_any_changes "$file"; then
                show_basic_output "$file" "$markdown"
            else
                show_no_changes "$markdown"
            fi
            ;;
        *)
            echo "Error: Invalid mode '$mode'" >&2
            exit 1
            ;;
    esac
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Show help if no arguments or help requested
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# Verify jq is available
check_jq

# Initialize variables
SHOW_MODE="$DEFAULT_MODE"
MARKDOWN="false"
GITHUB_COMMENT="false"

# Parse command line options
while [[ $1 == --* ]]; do
    case $1 in
        --short)
            SHOW_MODE="short"
            shift
            ;;
        --detail)
            SHOW_MODE="detail"
            shift
            ;;
        --no-op)
            SHOW_MODE="no-op"
            shift
            ;;
        --markdown)
            MARKDOWN="true"
            shift
            ;;
        --github-comment)
            GITHUB_COMMENT="true"
            MARKDOWN="true"
            shift
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            echo "Use -h or --help for usage information."
            exit 1
            ;;
    esac
done

# Validate input file
TFPLAN_FILE="$1"
if [ -z "$TFPLAN_FILE" ]; then
    echo "Error: No input file specified" >&2
    echo "Use -h or --help for usage information."
    exit 1
fi

if [ ! -f "$TFPLAN_FILE" ]; then
    echo "Error: File '$TFPLAN_FILE' not found" >&2
    exit 1
fi

# Execute analysis based on selected mode
if [ "$GITHUB_COMMENT" = "true" ]; then
    # For GitHub comment mode, capture output and check character limit
    OUTPUT=$(show_changes_output "$TFPLAN_FILE" "$MARKDOWN" "$SHOW_MODE")
    
    # Check character limit for GitHub comments
    check_github_comment_limit "$OUTPUT"
    
    # Output the result
    echo "$OUTPUT"
else
    # Normal execution without GitHub comment checks
    show_changes_output "$TFPLAN_FILE" "$MARKDOWN" "$SHOW_MODE"
fi

# =============================================================================
# END OF SCRIPT
# =============================================================================
