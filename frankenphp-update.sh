#!/usr/bin/env bash
set -u
export LC_ALL=C

TAG=${FRANKENPHP_TAG:-v1.13.2}
FORCE=${FORCE:-0}
CHECK_ONLY=0
PATHS=()

usage() {
  cat <<EOF
Usage: frankenphp-update.sh [--check] [path ...]
  path     a frankenphp binary or the directory containing it (default: auto-discover)
  --check  report only, change nothing
Environment: FRANKENPHP_TAG=$TAG (release to install), FORCE=1 (replace even if extensions differ)
From the network: curl -fsSL <URL> | sudo bash -s -- [--check] [path ...]
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) PATHS+=("$arg") ;;
  esac
done

say() {
  echo "[$(date +%H:%M:%S)] $*"
}

php_of() {
  timeout 15 "$1" version 2>/dev/null </dev/null | grep -oE -m1 'PHP [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2
}

min_fixed() {
  case "$1" in
    8.2) echo 8.2.35 ;;
    8.3) echo 8.3.36 ;;
    8.4) echo 8.4.27 ;;
    8.5) echo 8.5.12 ;;
  esac
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

is_fixed() {
  local fixed
  fixed=$(min_fixed "${1%.*}")
  if [ -n "$fixed" ]; then
    version_ge "$1" "$fixed"
  else
    version_ge "${1%.*}" 8.6
  fi
}

asset_digest() {
  awk -v want="$2" '
    /"name":/ { n = $0; gsub(/.*"name": *"|".*/, "", n); cur = n }
    /"digest":/ && cur == want { d = $0; gsub(/.*"digest": *"sha256:|".*/, "", d); print d; exit }
  ' <<<"$1"
}

discover() {
  find /home /root /srv /opt /var/www /usr/local -xdev -maxdepth 5 -type f -name frankenphp -size +50M -perm -u+x 2>/dev/null | sort -u
}

supervisor_programs_for() {
  local bin=$1 p exe pid prog line
  command -v supervisorctl >/dev/null 2>&1 || return 0
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    [ "$exe" = "$bin (deleted)" ] || [ "$exe" = "$bin" ] || continue
    pid=${p#/proc/}
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
      line=$(supervisorctl status 2>/dev/null | awk -v pid="$pid" '$2 == "RUNNING" && $4 == pid"," {print $1; exit}')
      if [ -n "$line" ]; then
        echo "$line"
        break
      fi
      pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
    done
  done | sort -u
}

update_one() {
  local bin=$1 old_php arch variant asset json digest new new_php dir old_ext new_ext missing programs prog
  [ -d "$bin" ] && bin=${bin%/}/frankenphp
  if [ ! -f "$bin" ] || [ ! -x "$bin" ]; then
    say "ERROR: $bin is not an executable file"
    return 1
  fi
  bin=$(readlink -f "$bin")
  old_php=$(php_of "$bin")
  if [ -z "$old_php" ]; then
    say "ERROR: $bin does not look like FrankenPHP (no PHP version in 'version' output)"
    return 1
  fi
  say "$bin: FrankenPHP with PHP $old_php"
  if is_fixed "$old_php"; then
    say "OK: PHP $old_php already contains the fix"
    return 0
  fi
  [ "$CHECK_ONLY" = 1 ] && { say "VULNERABLE: would update to FrankenPHP $TAG"; return 2; }

  arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ;;
    arm64) arch=aarch64 ;;
    *) say "ERROR: unsupported architecture $arch"; return 1 ;;
  esac
  variant=""
  ldd "$bin" >/dev/null 2>&1 && variant="-gnu"
  asset=frankenphp-linux-$arch$variant
  say "release $TAG, asset $asset"

  json=$(curl -fsSL -m 60 "https://api.github.com/repos/php/frankenphp/releases/tags/$TAG") || { say "ERROR: cannot read release $TAG from GitHub"; return 1; }
  digest=$(asset_digest "$json" "$asset")
  if [ -z "$digest" ]; then
    say "ERROR: GitHub returned no sha256 digest for $asset, refusing to install an unverified binary"
    return 1
  fi

  dir=$(dirname "$bin")
  new="$bin.new"
  if ! curl -fL --retry 3 -o "$new" "https://github.com/php/frankenphp/releases/download/$TAG/$asset"; then
    rm -f "$new"
    say "ERROR: download failed (disk space? network?)"
    return 1
  fi
  if ! echo "$digest  $new" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$new"
    say "ERROR: sha256 mismatch for the downloaded binary, nothing was changed"
    return 1
  fi
  chmod --reference="$bin" "$new" 2>/dev/null || chmod 755 "$new"
  chown --reference="$bin" "$new" 2>/dev/null

  new_php=$(php_of "$new")
  if [ -z "$new_php" ] || ! is_fixed "$new_php"; then
    rm -f "$new"
    say "ERROR: the new binary reports PHP '${new_php:-unknown}' which does not contain the fix, nothing was changed"
    return 1
  fi

  old_ext=$(timeout 30 "$bin" php-cli -m 2>/dev/null </dev/null | grep -E '^[A-Za-z0-9_ .-]+$' | sort -u)
  new_ext=$(timeout 30 "$new" php-cli -m 2>/dev/null </dev/null | grep -E '^[A-Za-z0-9_ .-]+$' | sort -u)
  missing=$(comm -23 <(echo "$old_ext") <(echo "$new_ext"))
  if [ -n "$missing" ]; then
    say "WARNING: extensions present in the old binary but missing in the new one:"
    echo "$missing" | sed 's/^/    /'
    if [ "$FORCE" != 1 ]; then
      rm -f "$new"
      say "Nothing was changed. Re-run with FORCE=1 if the application does not need them."
      return 1
    fi
  fi

  programs=$(supervisor_programs_for "$bin")
  cp -p "$bin" "$bin.bak-$old_php" && say "backup: $bin.bak-$old_php"
  mv -f "$new" "$bin" || { say "ERROR: cannot replace $bin"; return 1; }
  say "replaced: $("$bin" version 2>/dev/null | head -n1)"

  if [ -n "$programs" ]; then
    for prog in $programs; do
      say "restarting supervisor program $prog"
      supervisorctl restart "$prog" || say "ERROR: restart of $prog failed"
    done
  else
    say "WARNING: no supervisor program found for $bin, restart the FrankenPHP/Octane process yourself"
  fi
  return 0
}

main() {
  local bin rc=0 targets
  exec </dev/null
  if [ "$CHECK_ONLY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo bash -s -- ...)" >&2
    exit 2
  fi
  if [ "${#PATHS[@]}" -gt 0 ]; then
    targets=$(printf '%s\n' "${PATHS[@]}")
  else
    targets=$(discover)
    [ -n "$targets" ] || { say "no FrankenPHP binaries found"; exit 0; }
  fi
  while read -r bin; do
    [ -n "$bin" ] || continue
    update_one "$bin" </dev/null || rc=1
  done <<<"$targets"
  exit $rc
}

if [ -z "${FRANKENPHP_SOURCE_ONLY:-}" ]; then
  main
fi
