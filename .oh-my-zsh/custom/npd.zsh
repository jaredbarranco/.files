function npd () {
    if [[ ! -f package.json ]]; then
        echo "Error: package.json not found in current directory"
        return 1
    fi

    local version=$(node -p "require('./package.json').version")

    if [[ "$version" != *"DAT"* ]]; then
        echo "Error: version '$version' does not contain 'DAT'"
        return 1
    fi

    local prefix="${version%.*}"
    local last_digit="${version##*.}"
    local new_last_digit=$((last_digit + 1))
    local new_version="${prefix}.${new_last_digit}"

    node -e "
        const p = require('./package.json');
        p.version = '$new_version';
        require('fs').writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');
    "

    npm install --package-lock-only || return 1

    local ticket=$(echo "$version" | grep -oE 'DAT[0-9]+')

    git add package.json package-lock.json
    git commit -m "chore(deps): pip dev release $new_version" -m "$ticket"
}
