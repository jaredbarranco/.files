function getMulePrivateIp() {
  dig "mule-worker-internal-""$1"".us-e1.cloudhub.io"
}