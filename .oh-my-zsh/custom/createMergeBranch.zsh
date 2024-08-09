function createMergeBranch() {

# Check for uncommitted changes
if [[ $(git status --porcelain) ]]; then
    echo "Error: There are uncommitted changes. Please commit or stash them before running this script."
    return 1
fi

# Get the current branch name
current_branch=$(git symbolic-ref --short HEAD)

# Check if the current branch name already contains "-forMerge-"
if [[ "${current_branch}" == *"-forMerge_"* ]]; then
    echo "Error: The current branch name already contains '-forMerge_'. Exiting script."
    return 1
fi

# Get the short hash of the latest commit
short_hash=$(git log -1 --pretty=format:%h)

# Get the base branch from the input parameter or default to "develop"
base_branch=${1:-develop}

# Push changes to origin
git push origin "${current_branch}"

# Create a new branch with the specified suffix
new_branch="${current_branch}-forMerge_${short_hash}"
git checkout -b "${new_branch}"
echo "Created a new branch: ${new_branch}"

# Merge changes into the specified base branch
git merge "${base_branch}"



echo "Script completed successfully. - You should resolve the conflicts now...."

}


## Below version for my Linux friends
#
#
#!/bin/bash

# function createMergeBranch() {
#     local repo_dir=$1
#
#     # Check if the directory parameter is provided and valid
#     if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
#         echo "Error: Please provide a valid repository directory path."
#         return 1
#     fi
#
#     # Change to the specified repository directory
#     cd "$repo_dir" || return 1
#
#     # Check for uncommitted changes
#     if [[ $(git status --porcelain) ]]; then
#         echo "Error: There are uncommitted changes. Please commit or stash them before running this script."
#         return 1
#     fi
#
#     # Get the current branch name
#     current_branch=$(git symbolic-ref --short HEAD)
#
#     # Check if the current branch name already contains "-forMerge-"
#     if [[ "${current_branch}" == *"-forMerge_"* ]]; then
#         echo "Error: The current branch name already contains '-forMerge_'. Exiting script."
#         return 1
#     fi
#
#     # Get the short hash of the latest commit
#     short_hash=$(git log -1 --pretty=format:%h)
#
#     # Use the current branch name as the base branch
#     base_branch="${current_branch}"
#
#     # Push changes to origin
#     git push origin "${current_branch}"
#
#     # Create a new branch with the specified suffix
#     new_branch="${current_branch}-forMerge_${short_hash}"
#     git checkout -b "${new_branch}"
#     echo "Created a new branch: ${new_branch}"
#
#     # Merge changes into the specified base branch
#     git merge "${base_branch}"
#
#     echo "Script completed successfully. - You should resolve the conflicts now...."
# }
#
# # Call the function with the provided directory path
# createMergeBranch "$1"

