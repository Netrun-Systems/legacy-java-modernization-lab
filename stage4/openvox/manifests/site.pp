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

# Note: the db host (MySQL 8) is provisioned outside OpenVox in this lab.
# No petclinic::mysql class exists in this module; add one here when you
# want OpenVox to manage the database node.
#
# node 'db' {
#   include petclinic::mysql   # class not yet implemented
# }
