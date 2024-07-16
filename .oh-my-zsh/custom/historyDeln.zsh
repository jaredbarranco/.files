function historyDeln() {
  n=$(history 1 | awk '{print $1}')    # current history number
  historyDel $(( $n-$1 )) $(( $n-1 ))  # Call historyDel with ranges
}