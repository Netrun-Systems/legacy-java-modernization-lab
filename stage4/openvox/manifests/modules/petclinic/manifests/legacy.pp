# petclinic::legacy — manages Jetty 9.4 on the legacy-app host.
# Installs JDK 21, downloads Jetty 9.4 tarball, deploys the WAR,
# and manages the systemd unit. No Docker required on this node.
#
# The WAR is pre-built and staged to a URI the node can reach
# (in the lab: the Jenkins artifact server, or a simple HTTP server
# on the workstation). In production: Artifactory/Nexus.

class petclinic::legacy (
  String $jetty_version = lookup('petclinic::jetty_version'),
  Integer $port         = lookup('petclinic::port'),
  String $jdbc_url      = lookup('petclinic::jdbc_url'),
  String $jdbc_username = lookup('mysql::username'),
  String $jdbc_password = lookup('mysql::password'),

  # WAR source: replace with Artifactory URL in production.
  String $war_source = "http://${WORKSTATION_HOST}:8081/petclinic.war",

  String $install_dir = '/opt/petclinic-legacy',
  String $run_user    = 'petclinic',
) {
  # JDK 21 (temurin, via apt)
  package { 'temurin-21-jdk':
    ensure => present,
  }

  user { $run_user:
    ensure     => present,
    system     => true,
    managehome => false,
    shell      => '/sbin/nologin',
  }

  file { $install_dir:
    ensure => directory,
    owner  => $run_user,
    mode   => '0755',
  }

  # Download Jetty 9.4 tarball
  $jetty_tarball = "${install_dir}/jetty-home-${jetty_version}.tar.gz"
  $jetty_home    = "${install_dir}/jetty-home-${jetty_version}"
  $jetty_base    = "${install_dir}/base"

  archive { $jetty_tarball:
    ensure       => present,
    source       => "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-home/${jetty_version}/jetty-home-${jetty_version}.tar.gz",
    extract      => true,
    extract_path => $install_dir,
    creates      => $jetty_home,
    user         => $run_user,
    require      => File[$install_dir],
  }

  # Initialise Jetty base
  exec { 'jetty94-init-base':
    command => "java -jar ${jetty_home}/start.jar --jetty.base=${jetty_base} --add-to-start=http,deploy,jsp,jstl,annotations",
    creates => "${jetty_base}/start.d",
    path    => ['/usr/bin', '/usr/local/bin'],
    user    => $run_user,
    require => [Archive[$jetty_tarball], Package['temurin-21-jdk']],
  }

  # Deploy WAR
  archive { "${jetty_base}/webapps/petclinic.war":
    ensure  => present,
    source  => $war_source,
    require => Exec['jetty94-init-base'],
    notify  => Service['petclinic-legacy'],
  }

  # systemd unit
  file { '/etc/systemd/system/petclinic-legacy.service':
    ensure  => present,
    content => template('petclinic/petclinic-legacy.service.erb'),
    notify  => [Exec['systemd-daemon-reload'], Service['petclinic-legacy']],
  }

  exec { 'systemd-daemon-reload':
    command     => '/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'petclinic-legacy':
    ensure  => running,
    enable  => true,
    require => [File['/etc/systemd/system/petclinic-legacy.service'],
                Archive["${jetty_base}/webapps/petclinic.war"]],
  }
}
