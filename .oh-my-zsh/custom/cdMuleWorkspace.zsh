function cdMuleWorkspace () {
    if [ -z "$1" ]
    then
        cd ~/AnypointStudio/studio-workspace/
    else
        cd ~/AnypointStudio/studio-workspace/$1
    fi
}