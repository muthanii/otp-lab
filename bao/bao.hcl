ui            = true
disable_mlock = true

storage "raft" {
  path    = "/openbao/file"
  node_id = "bao1"
}

# Plain HTTP to keep the lab simple; use TLS for anything real.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://172.30.0.2:8200"
cluster_addr = "https://172.30.0.2:8201"
