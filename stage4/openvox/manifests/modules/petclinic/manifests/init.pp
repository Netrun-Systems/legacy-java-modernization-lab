# petclinic module — base class with Hiera lookups shared by all subclasses.
class petclinic (
  String $registry      = lookup('petclinic::registry'),
  String $image_name    = lookup('petclinic::image_name'),
  Integer $port         = lookup('petclinic::port'),
  String $jdbc_url      = lookup('petclinic::jdbc_url'),
  String $jdbc_username = lookup('mysql::username'),
  String $jdbc_password = lookup('mysql::password'),
) {
  # Base class is a parameter holder; subclasses do the actual resource work.
}
