# legacy-java-modernization-lab OpenVox control repo — site manifest
# Node classification by certname pattern (lab-grade; production uses
# an ENC/classifier like Foreman or PE Console).

node 'legacy-app' {
  include petclinic::legacy
}

node 'container-app' {
  include petclinic::container
}

node 'lb' {
  include petclinic::haproxy_node
}

node 'db-primary' {
  include petclinic::mysql_primary
}

node 'db-replica' {
  include petclinic::mysql_replica
}
