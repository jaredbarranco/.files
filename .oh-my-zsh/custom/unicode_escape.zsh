unicode_escape() {
  ## Used in a Cognito Payload - symbols required to be unicode
  local string="$1"
  local length="${#string}"
  local encoded=""
  local i=0
  while [ $i -lt $length ]; do
    local char="${string[i,1]}"
    local ascii=$(printf '%d' "'$char")
    if [ $ascii -gt 127 ]; then
      encoded="$encoded\\u$(printf '%04x' $ascii)"
    else
      encoded="$encoded$char"
    fi
    i=$((i + 1))
  done
  echo "$encoded"
}
