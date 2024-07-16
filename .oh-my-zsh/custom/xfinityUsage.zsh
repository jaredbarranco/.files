
function xfinityUsage () {
    if [ -z "$1" ]
    then
        curl http://192.168.0.135:7878 | jq '.'
        echo "Fetched from local network"
    else
        if [ "$1" = "tailscale" ] 
        then
            curl http://100.83.226.124:7878 | jq '.'
            echo "Fetched from Tailnet"
        fi
    fi
}