function ghProdPr () {
    
# Define an associative array for release options
release_options=(
    "Patch Release"
    "Minor Release"
    "Major Release"
)

# Prompt the user to select an option
PS3="Please select a release type (1-3): "

# Display the options and get the user's choice
select choice in "${release_options[@]}"; do
    case $choice in
        "Patch Release")
            LABEL="patch release"
            break
            ;;
        "Minor Release")
            LABEL="minor release"
            break
            ;;
        "Major Release")
            LABEL="major release"
            break
            ;;
        *)
            echo "Invalid option, please select 1, 2, or 3."
            ;;
    esac
done

# Display the selected option
echo "You selected: $LABEL release"


    gh pr create -B prod -H staging -l "$LABEL" -t "$(git branch --show-current)"
}