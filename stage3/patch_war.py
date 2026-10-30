"""
Patch petclinic.war in place so the same image digest can target
H2 (dev/test) and MySQL 8.4 (production) via runtime env vars.

Changes:
  1. datasource-config.xml: hardcoded driverClassName -> ${jdbc.driverClassName}
  2. datasource-config.xml: add ignore-failures="ALL" to jdbc:initialize-database
     so H2 handles the idempotent init scripts without erroring on DROP TABLE
  3. data-access.properties: restore dynamic db.script placeholders so
     jdbc.initLocation/dataLocation are overridable via -Djdbc.initLocation=...
  4. WEB-INF/lib/h2-2.1.214.jar: inject into WAR if /tmp/h2.jar present
     (MySQL profile build omits it; H2 driver must be on the WAR classpath)
"""
import zipfile
import os
import re

import glob as _glob
# Builder stage: /petclinic.war; runtime stage: /var/lib/jetty/webapps/petclinic.war
_candidates = ['/petclinic.war', '/var/lib/jetty/webapps/petclinic.war']
src = next((p for p in _candidates if os.path.exists(p)), None)
if src is None:
    raise FileNotFoundError("petclinic.war not found in expected locations")
tmp = '/petclinic.war.tmp'

print("Patching", src)
with zipfile.ZipFile(src, 'r') as zin:
    entries = {n: zin.read(n) for n in zin.namelist()}

# 1 & 2: datasource-config.xml
xml_key = 'WEB-INF/classes/spring/datasource-config.xml'
xml = entries[xml_key].decode('utf-8')
before = xml

xml = xml.replace(
    'p:driverClassName="com.mysql.cj.jdbc.Driver"',
    'p:driverClassName="${jdbc.driverClassName}"')
# URL, username, password are hardcoded literals in the source XML — not placeholders.
# Patch them so entrypoint.sh system properties can override for H2 or any target DB.
xml = xml.replace(
    'p:url="jdbc:mysql://localhost:3306/petclinic?useUnicode=true"',
    'p:url="${jdbc.url}"')
xml = xml.replace(
    'p:username="petclinic"',
    'p:username="${jdbc.username}"')
xml = xml.replace(
    'p:password="petclinic"',
    'p:password="${jdbc.password}"')
xml = xml.replace(
    '<jdbc:initialize-database data-source="dataSource">',
    '<jdbc:initialize-database data-source="dataSource" ignore-failures="ALL">')
entries[xml_key] = xml.encode('utf-8')

if xml != before:
    print("  datasource-config.xml: driverClassName/url/username/password now placeholders, ignore-failures=ALL")
else:
    print("  WARNING: datasource-config.xml unchanged - pattern may not have matched")
    print("  Content:", before[:500])

# 3: data-access.properties
prop_key = 'WEB-INF/classes/spring/data-access.properties'
props = entries[prop_key].decode('utf-8')
before_props = props

props = re.sub(
    r'jdbc\.initLocation=classpath:db/[^/\s]+/schema\.sql',
    'jdbc.initLocation=classpath:db/${db.script}/schema.sql',
    props)
props = re.sub(
    r'jdbc\.dataLocation=classpath:db/[^/\s]+/data\.sql',
    'jdbc.dataLocation=classpath:db/${db.script}/data.sql',
    props)
entries[prop_key] = props.encode('utf-8')

if props != before_props:
    print("  data-access.properties: db.script placeholders restored")
else:
    print("  data-access.properties: already uses placeholders or pattern did not match")

# 4: inject H2 driver JAR if present (MySQL build omits it)
h2_jar_path = '/tmp/h2.jar'
if os.path.exists(h2_jar_path):
    h2_key = 'WEB-INF/lib/h2-2.1.214.jar'
    if h2_key not in entries:
        with open(h2_jar_path, 'rb') as fh:
            entries[h2_key] = fh.read()
        print("  Injected", h2_key, "(%d bytes)" % len(entries[h2_key]))
    else:
        print("  H2 JAR already present, skipping injection")
else:
    print("  /tmp/h2.jar not found — H2 mode will fail at class-load (driver missing)")

with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zout:
    for name, data in entries.items():
        zout.writestr(name, data)
os.replace(tmp, src)
print("WAR patched successfully")
