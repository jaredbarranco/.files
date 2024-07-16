function cdGitRepo () {
    if [ -z "$1" ]
    then
        cd ~/Documents/Github
    else
        cd ~/Documents/Github/$1
    fi
}