#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 package.deb" >&2
  exit 2
fi

package=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb --extract "$package" "$tmp/root"
dpkg-deb --control "$package" "$tmp/control"

profile="$tmp/root/opt/CodeStatus/resources/apparmor-profile"
test -f "$profile" || {
  echo "the package has no AppArmor profile for unprivileged user namespaces" >&2
  exit 1
}
grep -Eq '^profile "codestatus" "/opt/CodeStatus/codestatus" flags=\(unconfined\)' "$profile" || {
  echo "the AppArmor profile does not target the installed executable" >&2
  exit 1
}
grep -Eq '^[[:space:]]*userns,' "$profile" || {
  echo "the AppArmor profile does not grant user namespaces" >&2
  exit 1
}
grep -q '/etc/apparmor.d' "$tmp/control/postinst" || {
  echo "postinst does not install the AppArmor profile" >&2
  exit 1
}

echo "linux package policy: ok"
