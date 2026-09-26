function npp () {
    if [[ ! -f package.json ]]; then
        echo "Error: package.json not found in current directory"
        return 1
    fi

    local version=$(node -p "require('./package.json').version")
    local level="${1:-patch}"

    local base_version="${version%%-*}"
    local major="${base_version%%.*}"
    local rest="${base_version#*.}"
    local minor="${rest%%.*}"
    local patch="${rest#*.}"

    case "$level" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch|*)
            patch=$((patch + 1))
            ;;
    esac

    local new_version="${major}.${minor}.${patch}"

    node -e "
        const p = require('./package.json');
        p.version = '$new_version';
        require('fs').writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');
    "

    npm install --package-lock-only || return 1

    git add package.json package-lock.json
    git commit -m "chore(deps): pip prod release $new_version"
}
