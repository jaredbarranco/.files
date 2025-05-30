function find-replace () {
    # Initialize default values
    local FILE_PATTERN="*.js,*.jsx,*.ts,*.tsx"
    local SEARCH_DIR="."
    local DRY_RUN=false
    local VERBOSE=false
    local OPERATIONS=()
    local SHOW_HELP=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file-pattern)
                FILE_PATTERN="$2"
                shift 2
                ;;
            -d|--directory)
                SEARCH_DIR="$2"
                shift 2
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            *)
                OPERATIONS+=("$1")
                shift
                ;;
        esac
    done

    # Show help if requested or no operations provided
    if [[ "$SHOW_HELP" == true || ${#OPERATIONS[@]} -eq 0 ]]; then
        echo "Script to perform find/replace operations in code files"
        echo ""
        echo "Usage:"
        echo "  find-replace [options] OPERATION [OPERATION...]"
        echo ""
        echo "Where OPERATION is in one of these formats:"
        echo "  - \"search_pattern:replace_pattern\" for replacements"
        echo "  - \"delete:pattern\" for deletions"
        echo ""
        echo "Options:"
        echo "  -f, --file-pattern   File extensions to search (comma-separated, default: \"*.js,*.jsx,*.ts,*.tsx\")"
        echo "  -d, --directory      Directory to start searching from (default: current directory)"
        echo "  -h, --help           Show this help message"
        echo "  -n, --dry-run        Show changes without applying them"
        echo "  -v, --verbose        Show detailed information about operations"
        echo ""
        echo "Examples:"
        echo "  # Replace all occurrences of foo with bar in JS files"
        echo "  find-replace \"foo:bar\""
        echo ""
        echo "  # Replace and delete in Python files"
        echo "  find-replace -f \"*.py\" \"import os:import os, sys\" \"delete:# TODO: remove this\""
        echo ""
        echo "  # Preview changes without applying them"
        echo "  find-replace -n \"console.log(:// console.log(\""
        return 0
    fi

    # Process operations to split by colon
    local PROCESSED_OPERATIONS=()
    for op in "${OPERATIONS[@]}"; do
        if [[ "$op" == delete:* ]]; then
            # For deletion operations
            pattern="${op#delete:}"
            PROCESSED_OPERATIONS+=("$pattern|")
        else
            # For replacement operations
            search_pattern="${op%%:*}"
            replace_pattern="${op#*:}"
            PROCESSED_OPERATIONS+=("$search_pattern|$replace_pattern")
        fi
    done

    # Show summary of operations
    echo "Starting code modifications from $SEARCH_DIR"
    echo "File pattern: $FILE_PATTERN"
    echo "Operations to perform:"
    for op in "${PROCESSED_OPERATIONS[@]}"; do
        search_pattern=$(echo "$op" | cut -d'|' -f1)
        replace_pattern=$(echo "$op" | cut -d'|' -f2)
        if [[ -z "$replace_pattern" ]]; then
            echo " - DELETE lines containing: '$search_pattern'"
        else
            echo " - REPLACE '$search_pattern' with '$replace_pattern'"
        fi
    done
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\nRunning in DRY RUN mode - no changes will be made."
    else
        echo -e "\nContinue with these operations? (y/n)"
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            return 0
        fi
    fi
    
    # Convert comma-separated pattern to find compatible pattern
    find_pattern=$(echo "$FILE_PATTERN" | sed 's/,/ -o -name /g')
    find_pattern="-name $find_pattern"
    
    # Find all matching files and process each one
    find "$SEARCH_DIR" -type f \( $find_pattern \) | while read -r file; do
        [[ "$VERBOSE" == true ]] && echo "Processing $file..."
        
        # Create a temporary file
        local temp_file=$(mktemp)
        
        # Copy original content to temp file
        cat "$file" > "$temp_file"
        
        # Apply each operation
        for op in "${PROCESSED_OPERATIONS[@]}"; do
            # Split operation into search and replace parts
            search_pattern=$(echo "$op" | cut -d'|' -f1)
            replace_pattern=$(echo "$op" | cut -d'|' -f2)
            
            if [[ -z "$replace_pattern" ]]; then
                # This is a deletion operation
                [[ "$VERBOSE" == true ]] && echo "  - Deleting lines containing: $search_pattern"
                grep -v "$search_pattern" "$temp_file" > "$temp_file.new" || true
                mv "$temp_file.new" "$temp_file"
            else
                # This is a replacement operation
                [[ "$VERBOSE" == true ]] && echo "  - Replacing: $search_pattern → $replace_pattern"
                sed -i'' "s|$search_pattern|$replace_pattern|g" "$temp_file" || true
            fi
        done
        
        # Check if file has changed
        if ! cmp -s "$file" "$temp_file"; then
            if [[ "$DRY_RUN" == true ]]; then
                echo "Would modify: $file"
                if [[ "$VERBOSE" == true ]]; then
                    echo "--- Original"
                    cat "$file" | grep -E "$search_pattern" | head -n 5
                    echo "--- Modified"
                    cat "$temp_file" | grep -E "$replace_pattern" | head -n 5
                    echo "---"
                fi
            else
                # Backup original file
                cp "$file" "${file}.bak"
                # Replace with modified content
                mv "$temp_file" "$file"
                echo "✓ Modified: $file (backup saved as ${file}.bak)"
            fi
        else
            [[ "$VERBOSE" == true ]] && echo "  - No changes needed in $file"
            rm "$temp_file"
        fi
    done
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\nDry run complete. No changes were made."
    else
        echo -e "\nAll operations completed!"
    fi
}
