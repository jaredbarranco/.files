function decryptMuleProperty() {
  java -cp /Users/jared/Documents/_MULESOFT/secure-properties-tool.jar com.mulesoft.tools.SecurePropertiesTool string decrypt Blowfish CBC "$1" "$2"
}