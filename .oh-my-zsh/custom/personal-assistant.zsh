function pa () {
    local KB_DIR="$HOME/Documents/personal/personal-kb"
    local MODEL=""
    local EDITOR_MODE=0
    local QUERY=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--model)
                MODEL="$2"
                shift 2
                ;;
            -e|--editor)
                EDITOR_MODE=1
                shift
                ;;
            -h|--help)
                echo "Personal assistant — queries your knowledge base via opencode"
                echo ""
                echo "Usage:"
                echo "  pa [options] <query>"
                echo ""
                echo "Options:"
                echo "  -e, --editor       Open \$EDITOR for a multiline prompt"
                echo "  -m, --model MODEL   Override the model (e.g. -m anthropic/claude-sonnet-4)"
                echo "  -h, --help          Show this help message"
                echo ""
                echo "Examples:"
                echo "  pa find notes about investing"
                echo "  pa -m anthropic/claude-sonnet-4 summarize my home projects"
                echo "  pa -e"
                return 0
                ;;
            *)
                QUERY+=("$1")
                shift
                ;;
        esac
    done

    if [[ $EDITOR_MODE -eq 1 ]]; then
        local EDITOR="${EDITOR:-nvim}"
        local TMPFILE=$(mktemp)
        echo "# Write your prompt below. Lines starting with '#' are ignored." > "$TMPFILE"
        $EDITOR "$TMPFILE"
        local PROMPT=$(grep -v '^#' "$TMPFILE" | sed '/^[[:space:]]*$/d')
        rm -f "$TMPFILE"
        if [[ -z "$PROMPT" ]]; then
            echo "No input provided. Aborting."
            return 1
        fi
        local CMD=(opencode run --agent personal --dir "$KB_DIR")
        if [[ -n "$MODEL" ]]; then
            CMD+=(--model "$MODEL")
        fi
        CMD+=("$PROMPT")
        "${CMD[@]}"
        return $?
    fi

    if [[ ${#QUERY[@]} -eq 0 ]]; then
        echo "Usage: pa [options] <query>"
        echo "Try 'pa --help' for more information."
        return 1
    fi

    local CMD=(opencode run --agent personal --dir "$KB_DIR")

    if [[ -n "$MODEL" ]]; then
        CMD+=(--model "$MODEL")
    fi

    CMD+=("${QUERY[@]}")

    "${CMD[@]}"
}
