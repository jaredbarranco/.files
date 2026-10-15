function awsx() {
    local sub="${1:-}"

    case "$sub" in
        whoami|id)
            aws sts get-caller-identity
            return $?
            ;;
        login)
            shift
            local session="$1"
            if [[ -z "$session" ]]; then
                echo "Enter SSO session name:"
                read -r session
            fi
            if [[ -z "$session" ]]; then
                echo "Error: no SSO session name provided."
                return 1
            fi
            aws sso login --sso-session "$session" --use-device-code --no-browser
            return $?
            ;;
        -h|--help|help|"")
            echo "Quick entry for common AWS commands"
            echo ""
            echo "Usage:"
            echo "  awsx whoami              Show the current caller identity"
            echo "  awsx login [session]     Start AWS SSO login (device code, no browser)"
            echo ""
            echo "Examples:"
            echo "  awsx whoami"
            echo "  awsx login my-sso-session"
            echo "  awsx login               # prompts for the session name"
            return 0
            ;;
        *)
            echo "Unknown subcommand: $sub"
            echo "Run 'awsx --help' for usage."
            return 1
            ;;
    esac
}
