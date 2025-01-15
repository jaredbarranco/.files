function uriencode () {
    if [ -z "$1" ]
    then
        echo "Enter your quoted string as the first parameter."
    else
        printf %s "$1" |jq -sRr @uri
    fi
}

