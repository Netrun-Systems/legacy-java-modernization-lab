# petclinic::container — manages Jetty 12.1 container on the container-app host.
# Uses a systemd unit with ExecStart=docker run ... by DIGEST, not by tag.
# OpenVox enforces the exact digest from Hiera — immutable artifact gate.
#
# PCI 11.5.2 angle: if someone manually docker pulls a different image
# and restarts the service, the next OpenVox run detects the digest mismatch
# (the running container's Image field != the Hiera-specified digest) and
# re-creates the service with the pinned image.
#
# Detection logic lives in the exec check below, not in the service block,
# because Puppet's service type only checks running/stopped, not image version.

class petclinic::container (
  String  $registry       = lookup('petclinic::registry'),
  String  $image_name     = lookup('petclinic::image_name'),
  String  $image_digest   = lookup('petclinic::image_digest'),
  Integer $port           = lookup('petclinic::port'),
  String  $jdbc_url       = lookup('petclinic::jdbc_url'),
  String  $jdbc_username  = lookup('mysql::username'),
  String  $jdbc_password  = lookup('mysql::password'),
) {
  package { 'docker.io':
    ensure => present,
  }

  service { 'docker':
    ensure  => running,
    enable  => true,
    require => Package['docker.io'],
  }

  $image_ref = "${registry}/${image_name}@${image_digest}"

  # Pull exact digest so the local image cache has it before unit start.
  exec { 'pull-petclinic-image':
    command => "docker pull '${image_ref}'",
    path    => ['/usr/bin', '/usr/local/bin'],
    unless  => "docker image inspect '${image_ref}' >/dev/null 2>&1",
    require => Service['docker'],
    notify  => Service['petclinic-container'],
  }

  # Detect running container digest mismatch → re-create.
  # "docker inspect" returns the image sha256 of the running container.
  # If it doesn't match $image_digest, kill and let the service re-create.
  exec { 'enforce-petclinic-digest':
    command => 'docker rm -f petclinic || true',
    path    => ['/usr/bin', '/usr/local/bin'],
    onlyif  => "test \"$(docker inspect petclinic --format='{{.Image}}' 2>/dev/null)\" != '${image_digest}'",
    notify  => Service['petclinic-container'],
    require => Service['docker'],
  }

  # systemd unit that runs the container on the pinned digest.
  file { '/etc/systemd/system/petclinic-container.service':
    ensure  => present,
    content => template('petclinic/petclinic-container.service.erb'),
    notify  => [Exec['systemd-daemon-reload-container'], Service['petclinic-container']],
  }

  exec { 'systemd-daemon-reload-container':
    command     => '/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'petclinic-container':
    ensure  => running,
    enable  => true,
    require => [File['/etc/systemd/system/petclinic-container.service'],
                Exec['pull-petclinic-image']],
  }
}
