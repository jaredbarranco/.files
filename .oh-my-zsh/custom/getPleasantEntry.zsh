#!/bin/bash

TOKENFILE=~/.pleasantToken.json

function getToken () {
   DOAPICALL=0
   #DEBUG=0
   #Do we have a cached token?
   if [[ $DEBUG -eq 1 ]]; then
      echo "getToken called with $1"
   fi
   if [[ -s $TOKENFILE ]]; then
      if [[ $DEBUG -eq 1 ]]; then
         echo "A token file exists"
      fi
	 	# Do we have a valid token stored?
      if [[ "$(jq '. | select(.access_token == null) | true' $TOKENFILE)" == "true" ]]; then
         if [[ $DEBUG -eq 1 ]]; then
            echo "Invalid token file, forcing refresh"
         fi
         DOAPICALL=1
      else
         if [[ $DEBUG -eq 1 ]]; then
            echo "Is the token valid?"
         fi
         #jq -nr 'now'
         #jq -r '.tokenExpires' $TOKENFILE 
	 		if [ "$( jq -nr 'now | strftime("%s")|tonumber')" -ge "$( jq -r '.tokenExpires' $TOKENFILE)" ]; then
            if [[ $DEBUG -eq 1 ]]; then
               echo "Token is no longer valid, forcing refresh"
            fi
            DOAPICALL=1
	 	   fi
      fi
   else
      if [[ $DEBUG -eq 1 ]]; then
         echo "No token file exists, forcing refresh"
      fi
      DOAPICALL=1
   fi

   if [[ $DOAPICALL -eq 1 ]]; then
      echo "Enter Pleasant Password:"
      read -s password

      echo "Pleasant MFA"
      read mfa

      #Get access token from Pleasant:
      curl -s -k --location --request POST 'https://pleasant:10001/OAuth2/Token' \
      --header 'X-Pleasant-OTP: '$mfa \
      --header 'X-Pleasant-OTP-Provider: authenticator-app' \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=password' \
      --data-urlencode 'username='$1 \
      --data-urlencode 'password='$password | \
      jq '. + {"tokenExpires": ((now | strftime("%s") | tonumber)-10 + .expires_in )}' > "$TOKENFILE"
	fi

   if test -s "$TOKENFILE"; then
      if [ "$( jq -nr 'now | strftime("%s")|tonumber')" -ge "$( jq -r '.tokenExpires' $TOKENFILE)" ]; then
         echo "Token is not valid - check password and 2FA . . . or the token expired during the run. Please try again"
         exit
      fi
   else
      echo "Call to Pleasant Failed - check your network settings or try to access Pleasant from another method"
      echo " . . . Are you connected to VPN?"
      exit
   fi
}


function getEnvVars() {
      
      
      #cat "$MAPFILE" | jq -rc '.'$ENV'.secrets[]'
            local SOURCEID="$1"
            echo "SOURCEID is " $SOURCEID
            #echo "$S"
            ## If the entry has a sourceId for pleasant, grab the pleasant object
        # Check validity of pleasant token prior to hitting APIs
        echo "Enter Pleasant User:"
        read PLEASANTUSER
        echo "Getting pleasant token with ""$PLEASANTUSER"
        getToken "$PLEASANTUSER"
        echo "Token got with ""$PLEASANTUSER"
        echo "Retrieving External Properties"
        
        #curl -s -k --location --request GET 'https://pleasant:10001/api/v6/rest/entries/'$SOURCEID --header 'Authorization: '"$(jq -r '.access_token' $TOKENFILE)" | jq -r '.'
        local ENTRY=$(curl -s -k --location --request GET 'https://pleasant:10001/api/v6/rest/entries/'$SOURCEID --header 'Authorization: '"$(jq -r '.access_token' $TOKENFILE)" | jq -r '.')
        #echo $ENTRY
        local ENTRY_PASS=$(curl -s -k --location --request GET "https://pleasant:10001/api/v6/rest/entries/$SOURCEID/password" --header 'Authorization: '"$(jq -r '.access_token' $TOKENFILE)" | jq '.')
        #echo $ENTRY_PASS   
            # Replace the default null password key/value with the actual password. Pass all authorities
            ENTRY=$(echo "$ENTRY" | jq 'del(.Password)')
            ENTRY=$(echo "$ENTRY" | jq '. + {"Password":'$ENTRY_PASS'}')
            echo $ENTRY | jq '.'
}


function retrieveExternalProperties() {
    local PROP_ENTRY="$1"
    #local ENV_VAR_IN="$1"
    #normalizeEnv "$ENV_VAR_IN"
    #if [[ $DEBUG -eq 1 ]]; then
    #    echo "Env normalized: ""$ENV"
    #fi
    #if [ -r "$PROP_FILE" ]
    #then
    #    true
    #else
    #    echo "$PROP_FILE"" : External Property file not readable!"
    #    exit
    #fi
    getEnvVars "$PROP_ENTRY"
    #alertOnNullExternalProperies "$EXTERNAL_PROPERTY_OBJECT"
}


#### START MAIN #####
function getPleasantEntry() {
retrieveExternalProperties "$1"
}
## If you want to call this as a normal bash script using: bash getPleasantEntry 'uuid-value-here', you should uncomment the line below
#getPleasantEntry "$1"
