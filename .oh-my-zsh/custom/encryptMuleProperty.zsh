function encryptMuleProperty() {
  java -cp /Users/jared/Documents/_MULESOFT/secure-properties-tool.jar com.mulesoft.tools.SecurePropertiesTool string encrypt Blowfish CBC "$1" "$2"
}