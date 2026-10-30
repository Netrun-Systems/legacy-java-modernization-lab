# petclinic::haproxy_node — installs and configures HAProxy on lb.
# The haproxy.cfg is sourced from the control repo (this module's files/).
# Weight changes happen via the admin socket (scripts/flip-weights.sh),
# NOT by editing haproxy.cfg, to avoid a config-file reload on every flip.

class petclinic::haproxy_node {
  package { 'haproxy':
    ensure => '2.9.*',  # Ubuntu 24.04 ships 2.9
  }

  file { '/etc/haproxy/haproxy.cfg':
    ensure  => present,
    source  => 'puppet:///modules/petclinic/haproxy.cfg',
    notify  => Service['haproxy'],
    require => Package['haproxy'],
  }

  # Admin socket dir (haproxy user needs write access)
  file { '/var/run/haproxy':
    ensure => directory,
    owner  => 'haproxy',
    mode   => '0770',
  }

  service { 'haproxy':
    ensure  => running,
    enable  => true,
    require => [Package['haproxy'], File['/etc/haproxy/haproxy.cfg']],
  }
}
