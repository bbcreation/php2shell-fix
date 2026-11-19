#!/usr/bin/env bash
set -u
export LC_ALL=C

VERSION=1.5.1
REPO_TAG=v1.5.1
FRANKENPHP_TAG=v1.13.6
CVES=(CVE-2026-129289 CVE-2026-115560 CVE-2026-126714)
MODE=check
RESTART=1
SWITCH_REPO=1
BUILD_SOURCE=1
MITIGATE=0
ASSUME_YES=0
APT_UPDATED=0
PLAN_ANY=0
declare -A REPORT=() BEFORE=()
CHANGED=0
APACHE_RESTART=0
MARKER_DIR=${MARKER_DIR:-/var/lib/php-smuggling-fix}
SURY_SOURCES=https://packages.sury.org/php/dists/bookworm/main/source/Sources.gz
SURY_INDEX=${SURY_INDEX:-/tmp/php-smuggling-sury-index-$$}
SURY_SKIP='telemetry|text-payload-to-send-CVE|README|NEWS|binary-distributions|garbage-collection|enchant_dict_is_in_session'
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=${LOG:-/var/log/php-smuggling-fix.log}
BACKUP_DIR=${BACKUP_DIR:-/root/php-smuggling-backup-$STAMP}
NGINX_DIRS=${NGINX_DIRS:-/etc/nginx /usr/local/hestia/data/templates/web/nginx}
APACHE_DIRS=${APACHE_DIRS:-/etc/apache2 /etc/httpd /usr/local/hestia/data/templates/web/apache2}
FPM_POOL_DIRS=${FPM_POOL_DIRS:-/etc/php /usr/local/etc /usr/local/hestia/php/etc}
PHP_ETC=${PHP_ETC:-/etc/php}
MITIGATION_INI=99-php-smuggling-mitigation.ini
PHP_DEB_RE='^(php[0-9]+\.[0-9]+(-[^ ]+)?|libapache2-mod-php[0-9]+\.[0-9]+|hestia-php|frankenphp) '

usage() {
  cat <<EOF
Usage: php-smuggling-fix.sh [options]   (from the network: curl -fsSL <URL> | sudo bash -s -- [options])
  --check            report only, no changes (default)
  --apply            upgrade PHP packages, rebuild package-less PHP (8.2-8.6 and hestia-php from the fixed release,
                     7.4/8.0/8.1 from the last release + the packages.sury.org security patches), fully restart php-fpm (needs root)
  --mitigate         turn off FastCGI connection reuse (nginx fastcgi_keep_conn, Apache enablereuse) and disable
                     session.upload_progress for PHP versions that are still unpatched (needs root, can be combined with --apply)
  --no-switch-repo   with --apply: do not switch from the ondrej/php PPA to packages.sury.org when the PPA has no fix yet
  --no-build-source  with --apply: do not build anything from source
  --no-restart       with --apply/--mitigate: do not restart or reload services
  -y, --yes          do not ask for confirmation (needed when there is no terminal, e.g. ssh in a loop)
  -h, --help         this help
Before --apply/--mitigate changes anything the script shows what it found and what it will do, and asks for confirmation.
Exit code: 0 = everything patched or no PHP found, 1 = vulnerable binaries left or processes still on the old binary, 3 = not confirmed
Last line: RESULT host=... status=OK|NOPHP|STALE|VULNERABLE|MANUAL|ABORTED changed=0|1
EOF
}

emit() {
  echo "$*"
  { echo "$*" >>"$LOG"; } 2>/dev/null
}

log() {
  emit "[$(date +%H:%M:%S)] $*"
}

min_fixed() {
  case "$1" in
    8.2) echo 8.2.36 ;;
    8.3) echo 8.3.37 ;;
    8.4) echo 8.4.28 ;;
    8.5) echo 8.5.13 ;;
    8.6) echo 8.6.0 ;;
  esac
}

debian_version() {
  echo "$1" | sed -E 's/-dev$/~dev/; s/(alpha|beta|RC)/~\1/'
}

version_ge() {
  dpkg --compare-versions "$(debian_version "$1")" ge "$(debian_version "$2")"
}

php_package_snapshot() {
  dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' 2>/dev/null \
    | awk '$3 ~ /^ii/ {print $1, $2}' | grep -E "$PHP_DEB_RE" | sort
}

package_binaries() {
  local pkg
  for pkg in $(php_package_snapshot | awk '{print $1}' | sort -u); do
    dpkg -L "$pkg" 2>/dev/null
  done | grep -E '/(php|php-fpm|php-cgi|hestia-php|frankenphp)[0-9.]*$'
}

collect_binaries() {
  local c p
  {
    command -v php
    package_binaries
    for c in /usr/bin/php* /usr/sbin/php* /usr/local/bin/php* /usr/local/sbin/php-fpm* /usr/local/php*/bin/php* /usr/local/php*/sbin/php-fpm* /usr/local/hestia/php/sbin/hestia-php /usr/bin/frankenphp /usr/local/bin/frankenphp; do
      echo "$c"
    done
    find /opt /usr/local /srv /home /root -xdev -maxdepth 6 \( -name node_modules -o -name vendor \) -prune -o \
      -type f -perm -u+x -size +1M \( -name php -o -name 'php[0-9]*' -o -name 'php-fpm*' -o -name 'php-cgi*' -o -name frankenphp \) -print 2>/dev/null
    for p in /proc/[0-9]*/exe; do
      readlink "$p" 2>/dev/null
    done
  } | sed 's/ (deleted)$//' | while read -r c; do
    case "$(basename "$c")" in
      php|php[0-9]*|php-fpm*|php-cgi*|hestia-php|frankenphp) ;;
      *) continue ;;
    esac
    [ -f "$c" ] && [ -x "$c" ] || continue
    readlink -f "$c"
  done | sort -u
}

binary_version() {
  local arg=-v
  [ "$(basename "$1")" = frankenphp ] && arg=version
  timeout 10 "$1" $arg 2>/dev/null </dev/null | grep -oE -m1 'PHP [0-9]+\.[0-9]+\.[0-9]+((alpha|beta|RC)[0-9]*|-dev)?' | head -n1 | cut -d' ' -f2
}

binary_owner() {
  dpkg -S "$1" 2>/dev/null </dev/null | head -n1 | cut -d: -f1
}

package_has_fix() {
  local pkg=$1 cve
  [ -n "$pkg" ] || return 1
  for cve in "${CVES[@]}"; do
    { zcat -f "/usr/share/doc/$pkg/changelog.Debian.gz" 2>/dev/null; zcat -f "/usr/share/doc/$pkg/changelog.gz" 2>/dev/null; } | grep -q "$cve" || return 1
  done
  return 0
}

installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

sury_version() {
  apt-cache madison "$1" 2>/dev/null | grep packages.sury.org | head -n1 | awk '{print $3}'
}

upstream_version() {
  local v=${1#*:}
  echo "${v%%-*}"
}

proc_cmdline() {
  { tr '\0' ' ' <"/proc/$1/cmdline"; } 2>/dev/null
}

run_logged() {
  local out rc line
  out=$("$@" 2>&1)
  rc=$?
  { echo "$out" >>"$LOG"; } 2>/dev/null
  while read -r line; do
    case "$line" in
      "systemctl restart "*) log "needrestart: ${line}" ;;
    esac
  done <<<"$out"
  if [ "$rc" != 0 ]; then
    echo "$out" | grep -vE '^(Reading|Preparing|Unpacking|Selecting|Setting up|Processing|\(Reading)' | tail -n 20
  fi
  return "$rc"
}

binary_hash() {
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

configure_command() {
  timeout 10 "$1" -i 2>/dev/null </dev/null | sed -n 's/^Configure Command => *//p' | head -n1
}

configure_prefix() {
  local prefix
  prefix=$(echo "$1" | grep -oE "'--prefix=[^']*'" | head -n1 | cut -d= -f2 | tr -d "'")
  echo "${prefix:-/usr/local}"
}

source_build_marked() {
  local hash
  hash=$(binary_hash "$1")
  [ -n "$hash" ] && [ -f "$MARKER_DIR/$hash.fixed" ]
}

mark_source_build() {
  mkdir -p "$MARKER_DIR"
  echo "$2 $(date -u +%FT%TZ)" >"$MARKER_DIR/$(binary_hash "$1").fixed"
}

eol_tag() {
  case "$1" in
    7.4) echo php-7.4.33 ;;
    8.0) echo php-8.0.30 ;;
    8.1) echo php-8.1.34 ;;
  esac
}

sury_source_entry() {
  zcat -f | awk -v want="php$1" '
    /^Package: / { pkg = $2; ver = ""; dir = ""; sha = 0 }
    pkg == want && /^Version: / { ver = $2 }
    pkg == want && /^Directory: / { dir = $2 }
    pkg == want && /^Checksums-Sha256:/ { sha = 1; next }
    pkg == want && sha && /^ / && $3 ~ /\.debian\.tar\.xz$/ { print ver, dir, $3, $1; exit }
    /^[A-Z]/ { sha = 0 }
  '
}

fetch_sury_patches() {
  local branch=$1 dest=$2 entry ver dir file sum fixed
  entry=$(curl -fsSL -m 60 "$SURY_SOURCES" | sury_source_entry "$branch")
  read -r ver dir file sum <<<"$entry"
  [ -n "${sum:-}" ] || { echo "no php$branch source package on packages.sury.org"; return 1; }
  fixed=$(sury_fixed_revision "$branch")
  dpkg --compare-versions "${ver#*:}" ge "$fixed" || { echo "packages.sury.org has php$branch $ver, older than $fixed"; return 1; }
  curl -fsSL -m 120 -o "$dest/sury.debian.tar.xz" "https://packages.sury.org/php/$dir/$file" || return 1
  echo "$sum  $dest/sury.debian.tar.xz" | sha256sum -c - >/dev/null || { echo "sha256 mismatch for $file"; return 1; }
  tar xJf "$dest/sury.debian.tar.xz" -C "$dest" debian/patches || return 1
  echo "$ver"
}

apply_sury_patches() {
  local patches=$1 from p bad
  from=$(grep -nE 'README' "$patches/series" | head -n1 | cut -d: -f1)
  [ -n "$from" ] || { echo "cannot find the end of the Debian packaging patches"; return 1; }
  for p in $(tail -n +"$((from + 1))" "$patches/series" | grep -vE "$SURY_SKIP"); do
    patch -p1 -s -f --no-backup-if-mismatch <"$patches/$p" >/dev/null 2>&1
  done
  bad=$(find . -name '*.rej' | grep -vE '^\./NEWS\.rej$|/tests/')
  [ -z "$bad" ] || { echo "patch hunks rejected outside NEWS and tests: $bad"; return 1; }
  find . -name '*.rej' -delete
  grep -q 'partially read STDIN record' main/fastcgi.c || { echo "the CVE-2026-129289 fix is missing after patching"; return 1; }
  grep -q zend_mm_safe_error_ex Zend/zend_alloc.c || { echo "the CVE-2026-109618 fix is missing after patching"; return 1; }
  ! grep -rq secure_dns_telemetry main sapi || { echo "the telemetry patch got in"; return 1; }
}

BUILD_DEP_MAP=(
  'with-openssl=libssl-dev'
  'with-curl=libcurl4-openssl-dev'
  'with-zlib|with-gd|enable-gd=zlib1g-dev'
  'with-jpeg|with-jpeg-dir=libjpeg-dev'
  'with-png|with-png-dir=libpng-dev'
  'with-freetype|with-freetype-dir=libfreetype-dev/libfreetype6-dev'
  'with-webp|with-webp-dir=libwebp-dev'
  'enable-mbstring=libonig-dev'
  'with-zip|enable-zip=libzip-dev'
  'enable-intl=libicu-dev'
  'with-sodium=libsodium-dev'
  'with-pgsql|with-pdo-pgsql=libpq-dev'
  'with-xsl=libxslt1-dev'
  'with-gmp=libgmp-dev'
  'with-bz2=libbz2-dev'
  'with-readline=libreadline-dev'
  'with-libedit=libedit-dev'
  'with-ldap=libldap2-dev'
  'with-password-argon2=libargon2-dev'
  'with-kerberos=libkrb5-dev'
  'with-tidy=libtidy-dev'
  'with-ffi=libffi-dev'
  'with-fpm-systemd=libsystemd-dev'
  'with-apxs2=apache2-dev'
  'with-enchant=libenchant-2-dev/libenchant-dev'
  'with-snmp=libsnmp-dev'
  'with-unixODBC|with-pdo-odbc=unixodbc-dev'
)

package_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

build_dep_packages() {
  local cmd=$1 entry regex alts alt
  echo "build-essential autoconf automake libtool bison re2c pkg-config curl tar patch xz-utils ca-certificates libxml2-dev libsqlite3-dev" | tr ' ' '\n'
  for entry in "${BUILD_DEP_MAP[@]}"; do
    regex=${entry%%=*}
    alts=${entry#*=}
    echo "$cmd" | grep -qE "'--($regex)(=[^']*)?'" || continue
    for alt in $(echo "$alts" | tr '/' ' '); do
      if package_exists "$alt"; then
        echo "$alt"
        break
      fi
    done
  done
}

ensure_build_deps() {
  local branch=$1 cmd=$2 pkg missing=() sslver
  for pkg in $(build_dep_packages "$cmd" | sort -u); do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "installing build dependencies for PHP $branch: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; } \
      || { log "ERROR: could not install: ${missing[*]}, skipping the PHP $branch build"; return 1; }
  fi
  if echo "$cmd" | grep -qE "'--with-openssl(=[^']*)?'" && { [ "$branch" = 7.4 ] || [ "$branch" = 8.0 ]; }; then
    sslver=$(pkg-config --modversion openssl 2>/dev/null)
    case "$sslver" in
      3*) log "ERROR: PHP $branch does not support OpenSSL $sslver (this system) and cannot be built here, use the packages.sury.org packages"; return 1 ;;
    esac
  fi
  return 0
}

build_and_install() {
  local branch=$1 tag=$2 sury=$3 cmd=$4 binlist=$5 dir prefix jobs tool b after hestia=0 rc label=$2 rev=""
  local -A before=()
  ensure_build_deps "$branch" "$cmd" || return 1
  for tool in gcc make autoconf bison re2c curl tar patch xz; do
    command -v "$tool" >/dev/null 2>&1 || { log "ERROR: '$tool' is still missing after installation, skipping the PHP $branch build"; return 1; }
  done
  dir=/usr/local/src/php-smuggling-$branch-$STAMP-$$-$RANDOM
  jobs=$(nproc 2>/dev/null || echo 2)
  [ "$jobs" -gt 4 ] && jobs=4
  mkdir -p "$dir"
  if [ "$sury" = 1 ]; then
    mkdir -p "$dir.sury"
    rev=$(fetch_sury_patches "$branch" "$dir.sury" 2>&1 | tail -n1)
    [ -f "$dir.sury/debian/patches/series" ] || { log "ERROR: cannot get the packages.sury.org patches for PHP $branch: $rev"; return 1; }
    label="$tag + packages.sury.org php$branch $rev security patches"
  fi
  log "building PHP $branch from $label (log: $dir.log)"
  (
    set -e
    set -o pipefail
    cd "$dir"
    curl -fsSL "https://github.com/php/php-src/archive/refs/tags/$tag.tar.gz" | tar xz --strip-components=1
    if [ "$sury" = 1 ]; then
      apply_sury_patches "$dir.sury/debian/patches"
    fi
    ./buildconf --force
    eval "set -- $cmd"
    shift
    ./configure "$@"
    nice -n 19 make -j"$jobs"
    sapi/cli/php -v | grep -q "^PHP ${tag#php-} "
  ) >"$dir.log" 2>&1 </dev/null || { log "ERROR: building PHP $branch failed, old binaries untouched, log: $dir.log"; return 1; }
  prefix=$(configure_prefix "$cmd")
  while read -r b; do
    [ -n "$b" ] && before[$b]=$(binary_hash "$b")
  done <<<"$binlist"
  mkdir -p "$BACKUP_DIR"
  tar czf "$BACKUP_DIR/php-$branch-$(echo "$prefix" | tr / _).tgz" -C "$prefix" $(cd "$prefix" && ls -d bin sbin 2>/dev/null) 2>/dev/null
  echo "$cmd" | grep -q 'apxs' && log "WARNING: PHP $branch has mod_php (apxs), make install may modify the Apache configuration"
  [ "$prefix" = /usr/local/hestia/php ] && hestia=1
  [ "$hestia" = 1 ] && systemctl stop hestia >/dev/null 2>&1
  (cd "$dir" && make install) >>"$dir.log" 2>&1 </dev/null
  rc=$?
  if [ "$rc" = 0 ] && [ "$hestia" = 1 ]; then
    cp -f "$prefix/sbin/php-fpm" "$prefix/sbin/hestia-php.new" && mv -f "$prefix/sbin/hestia-php.new" "$prefix/sbin/hestia-php" || rc=1
  fi
  [ "$hestia" = 1 ] && systemctl start hestia >/dev/null 2>&1
  [ "$rc" = 0 ] || { log "ERROR: make install for PHP $branch failed, log: $dir.log, backup: $BACKUP_DIR"; return 1; }
  CHANGED=1
  while read -r b; do
    [ -n "$b" ] || continue
    after=$(binary_hash "$b")
    if [ "$after" != "${before[$b]:-}" ] && [ "$(binary_version "$b")" = "${tag#php-}" ]; then
      [ "$sury" = 1 ] && mark_source_build "$b" "$tag+sury-$rev"
      log "installed $label: $b (backup of old binaries: $BACKUP_DIR)"
    else
      log "WARNING: $b did not change after make install, check that the prefix ($prefix) is correct"
    fi
  done <<<"$binlist"
  rm -rf "$dir" "$dir.sury"
  return 0
}

source_buildable() {
  [ "$(basename "$1")" = frankenphp ] && return 1
  case "$1" in
    /usr/local/hestia/php/*) return 0 ;;
  esac
  [ -z "$(binary_owner "$1")" ]
}

source_build_target() {
  local bin=$1 ver=$2 branch fixed tag sury=0 cmd prefix
  branch=${ver%.*}
  fixed=$(min_fixed "$branch")
  if [ -n "$fixed" ]; then
    tag=php-$fixed
  else
    tag=$(eol_tag "$branch")
    [ -n "$tag" ] || { echo "PHP $branch is end of life and nobody publishes a source fix for it, move to a supported PHP or the packages.sury.org build"; return 1; }
    sury=1
  fi
  cmd=$(configure_command "$bin")
  [ -n "$cmd" ] || { echo "cannot read the Configure Command from $bin, rebuild it by hand"; return 1; }
  prefix=$(configure_prefix "$cmd")
  case "$bin" in
    "$prefix"/bin/*|"$prefix"/sbin/*) ;;
    *) echo "$bin is outside its configure prefix ($prefix), rebuild it by hand"; return 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$branch" "$tag" "$sury" "$cmd"
}

build_source_release() {
  local entry bin ver branch tag sury cmd key target
  local -a keys=()
  local -A bins=() meta=()
  for entry in "${UNPATCHED[@]:-}"; do
    [ -n "$entry" ] || continue
    bin=${entry%%|*}
    ver=${entry##*|}
    [ -n "$ver" ] || continue
    source_buildable "$bin" || continue
    if ! target=$(source_build_target "$bin" "$ver"); then
      log "MANUAL: $target"
      continue
    fi
    IFS=$'\t' read -r branch tag sury cmd <<<"$target"
    key="$tag $sury $cmd"
    if [ -z "${meta[$key]:-}" ]; then
      keys+=("$key")
      meta[$key]=$target
    fi
    bins[$key]+="$bin"$'\n'
  done
  for key in "${keys[@]:-}"; do
    [ -n "$key" ] || continue
    IFS=$'\t' read -r branch tag sury cmd <<<"${meta[$key]}"
    build_and_install "$branch" "$tag" "$sury" "$cmd" "${bins[$key]}"
  done
}

assess_binary() {
  local bin=$1 ver branch fixed pkg state
  ver=$(binary_version "$bin")
  pkg=$(binary_owner "$bin")
  if [ -z "$ver" ]; then
    if [ -n "$pkg" ]; then
      echo "UNKNOWN||$pkg"
    else
      echo "SKIP||"
    fi
    return
  fi
  branch=${ver%.*}
  fixed=$(min_fixed "$branch")
  if [ -n "$fixed" ] && version_ge "$ver" "$fixed"; then
    state=PATCHED
  elif version_ge "$branch" 8.7; then
    state=PATCHED
  elif package_has_fix "$pkg"; then
    state=PATCHED
  elif source_build_marked "$bin"; then
    state=PATCHED
  elif [ -z "$pkg" ]; then
    state=SOURCE
  else
    state=VULNERABLE
  fi
  echo "$state|$ver|$pkg"
}

binary_origin() {
  local bin=$1 pkg=$2 ver
  [ "$(basename "$bin")" = frankenphp ] && { echo frankenphp; return; }
  case "$bin" in
    /usr/local/hestia/php/*) echo hestia; return ;;
  esac
  [ -n "$pkg" ] || { echo source; return; }
  case "$(package_source "$pkg")" in
    *packages.sury.org*) echo sury; return ;;
    *launchpad*ondrej*) echo ppa-ondrej; return ;;
    http*) echo distro; return ;;
  esac
  ver=$(installed_version "$pkg")
  case "$ver" in
    *deb.sury.org*|*debsuryorg*)
      if ondrej_ppa_in_use && ! sury_repo_present; then echo ppa-ondrej; else echo sury; fi ;;
    *) echo distro ;;
  esac
}

safe_version() {
  local ver=$1 origin=$2 branch fixed
  branch=${ver%.*}
  [ "$origin" = frankenphp ] && { echo "$(min_fixed "$branch")"; return; }
  origin=${origin%+sury}
  fixed=$(min_fixed "$branch")
  [ -n "$fixed" ] && { echo "$fixed"; return; }
  version_ge "$branch" 8.7 && { echo "$ver"; return; }
  case "$origin" in
    sury|ppa-ondrej) echo "$(sury_fixed_revision "$branch")" ;;
    distro) echo "changelog:${CVES[0]}" ;;
    *) [ -n "$(eol_tag "$branch")" ] && echo "$(eol_tag "$branch" | sed 's/^php-//')+sury" || echo "none (EOL)" ;;
  esac
}

package_source() {
  apt-cache policy "$1" 2>/dev/null | awk '
    /^ \*\*\* / { inst = 1; next }
    inst && /^        [0-9]+ [a-z]+:/ { print $2; exit }
    inst && !/^        / { exit }
  '
}

sury_codename() {
  echo "$(lsb_release -sc 2>/dev/null)/$(dpkg --print-architecture 2>/dev/null)"
}

sury_index_version() {
  local cn
  if [ ! -s "$SURY_INDEX" ]; then
    cn=$(sury_codename)
    curl -fsSL -m 60 "https://packages.sury.org/php/dists/${cn%/*}/main/binary-${cn#*/}/Packages.gz" 2>/dev/null | zcat -f >"$SURY_INDEX" 2>/dev/null
  fi
  awk -v want="$1" '$0 == "Package: " want { f = 1 } f && /^Version:/ { print $2; exit }' "$SURY_INDEX" 2>/dev/null
}

sury_has_fix() {
  local v
  v=$(sury_index_version "$1")
  [ -n "$v" ] && candidate_is_fixed "$v"
}

package_candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'
}

binary_action() {
  local bin=$1 state=$2 ver=$3 pkg=$4 inst cand target branch tag sury cmd
  case "$state" in
    PATCHED) echo "nothing to do"; return ;;
    UNKNOWN) echo "cannot read the PHP version, check it by hand"; return ;;
  esac
  if [ "$(basename "$bin")" = frankenphp ]; then
    echo "update with frankenphp-update.sh (FrankenPHP $FRANKENPHP_TAG)"
    return
  fi
  if [ -n "$pkg" ]; then
    inst=$(installed_version "$pkg")
    cand=$(package_candidate "$pkg")
    if [ -n "$cand" ] && [ "$cand" != "(none)" ] && [ "$cand" != "$inst" ]; then
      if candidate_is_fixed "$cand"; then
        echo "apt upgrade $pkg $inst -> $cand"
      else
        echo "apt upgrade $pkg $inst -> $cand (the version alone does not prove the fix, the changelog is checked afterwards)"
      fi
      return
    fi
    if [ "$APT_UPDATED" = 0 ]; then
      if [ "$SWITCH_REPO" = 1 ] && ondrej_ppa_in_use && ! sury_repo_present; then
        echo "no newer $pkg in the local package lists (--check does not run apt-get update); --apply refreshes them first and switches the ondrej/php PPA to packages.sury.org if it still has nothing newer"
      else
        echo "no newer $pkg in the local package lists (--check does not run apt-get update); --apply refreshes them first"
      fi
      return
    fi
    if [ "$SWITCH_REPO" = 1 ] && ondrej_ppa_in_use && ! sury_repo_present; then
      if sury_has_fix "$pkg"; then
        echo "the ondrej/php PPA has no newer $pkg: switch to packages.sury.org ($(sury_codename)) and upgrade to $(sury_index_version "$pkg")"
      else
        echo "neither the ondrej/php PPA nor packages.sury.org ($(sury_codename)) has a fixed $pkg yet: use --mitigate now and --apply again later"
      fi
      return
    fi
    case "$bin" in
      /usr/local/hestia/php/*) ;;
      *) echo "no fixed $pkg in the repositories yet: use --mitigate now and --apply again later"; return ;;
    esac
  fi
  if [ "$BUILD_SOURCE" = 0 ]; then
    echo "building from source is off (--no-build-source): fix it by hand"
    return
  fi
  if ! target=$(source_build_target "$bin" "$ver"); then
    echo "MANUAL: $target"
    return
  fi
  IFS=$'\t' read -r branch tag sury cmd <<<"$target"
  if [ "$sury" = 1 ]; then
    echo "build $tag + the packages.sury.org security patches from source, install into $(configure_prefix "$cmd") (takes 5-20 minutes)"
  else
    echo "build $tag from source, install into $(configure_prefix "$cmd") (takes 5-20 minutes)"
  fi
}

print_report() {
  local quiet=${1:-} bin line state ver pkg origin
  OK=0
  BAD=0
  MANUAL=0
  UNPATCHED=()
  PLAN=()
  [ -n "$quiet" ] || REPORT=()
  [ -n "$quiet" ] || emit "$(printf '%-10s %-11s %-16s %-11s %-26s %s' STATE VERSION SAFE ORIGIN PACKAGE BINARY)"
  while read -r bin; do
    [ -n "$bin" ] || continue
    line=$(assess_binary "$bin" </dev/null)
    state=${line%%|*}
    [ "$state" = SKIP ] && continue
    ver=$(echo "$line" | cut -d'|' -f2)
    pkg=$(echo "$line" | cut -d'|' -f3)
    if [ -z "$quiet" ]; then
      origin=$(binary_origin "$bin" "$pkg")
      [ "$origin" = source ] && source_build_marked "$bin" && origin=source+sury
      REPORT[$bin]="$state|$ver|$pkg|$( [ -n "$pkg" ] && installed_version "$pkg")|$origin"
      emit "$(printf '%-10s %-11s %-16s %-11s %-26s %s' "$state" "${ver:--}" "$( [ -n "$ver" ] && safe_version "$ver" "$origin" || echo -)" "$origin" "${pkg:--}" "$bin")"
      [ "$state" = PATCHED ] || PLAN+=("$bin: $(binary_action "$bin" "$state" "$ver" "$pkg" </dev/null)")
    fi
    case "$state" in
      PATCHED) OK=$((OK+1)) ;;
      SOURCE|UNKNOWN) MANUAL=$((MANUAL+1)); UNPATCHED+=("$bin|$ver") ;;
      VULNERABLE) BAD=$((BAD+1)); UNPATCHED+=("$bin|$ver") ;;
    esac
  done < <(collect_binaries)
}

print_summary() {
  local bin a b astate aver apkg apv aorig bstate bver bpkg bpv borig total=0 safe=0 unsafe=0 extra
  emit "--- result ---"
  for bin in $(printf '%s\n' "${!REPORT[@]}" | sort); do
    a=${REPORT[$bin]}
    b=${BEFORE[$bin]:-}
    IFS='|' read -r astate aver apkg apv aorig <<<"$a"
    IFS='|' read -r bstate bver bpkg bpv borig <<<"$b"
    total=$((total + 1))
    if [ "$astate" != PATCHED ]; then
      unsafe=$((unsafe + 1))
      emit "STILL UNSAFE  $bin: PHP ${aver:-unknown}, safe from $( [ -n "$aver" ] && safe_version "$aver" "$aorig" || echo unknown)"
      continue
    fi
    safe=$((safe + 1))
    if [ "$bstate" = PATCHED ] && [ "$bver" = "$aver" ] && [ "$bpv" = "$apv" ]; then
      emit "ALREADY SAFE  $bin: PHP $aver"
    elif [ -n "$apkg" ]; then
      emit "UPGRADED      $bin: PHP ${bver:-unknown} -> $aver ($apkg ${bpv:-unknown} -> $apv, ${borig:-unknown} -> $aorig)"
    else
      extra=""
      [ "$aorig" = source+sury ] && extra=" + packages.sury.org security patches"
      emit "UPGRADED      $bin: PHP ${bver:-unknown} -> $aver$extra (built from source)"
    fi
  done
  emit "SUMMARY       $safe of $total PHP binaries are safe, $unsafe still unsafe"
}

print_plan() {
  local line f branch sapi any=0
  emit "--- plan ---"
  for line in "${PLAN[@]:-}"; do
    [ -n "$line" ] || continue
    emit "  $line"
    any=1
  done
  if [ "$MITIGATE" = 1 ]; then
    while read -r f; do
      [ -n "$f" ] && { emit "  $f: fastcgi_keep_conn on -> off, then nginx -t and reload"; any=1; }
    done <<<"$(keep_conn_files)"
    while read -r f; do
      [ -n "$f" ] && { emit "  $f: enablereuse=on -> off, then apache2ctl -t and reload"; any=1; }
    done <<<"$(reuse_files)"
    for branch in $(unpatched_branches); do
      for sapi in fpm cgi apache2; do
        [ -d "$PHP_ETC/$branch/$sapi/conf.d" ] && { emit "  write $PHP_ETC/$branch/$sapi/conf.d/$MITIGATION_INI (session.upload_progress.enabled = 0)"; any=1; }
      done
    done
  fi
  if [ "$MODE" = apply ] || [ "$MITIGATE" = 1 ]; then
    [ -n "$(stale_processes)" ] && { emit "  some processes still run an old (deleted) PHP binary"; any=1; }
  fi
  if [ "$any" = 1 ] && [ "$RESTART" = 1 ]; then
    emit "  full restart of PHP-FPM afterwards (new binary, empty OPcache):"
    while read -r line; do
      [ -n "$line" ] && emit "    $line"
    done <<<"$(describe_fpm_targets)"
    [ -n "$(fpm_targets)" ] || emit "    no running php-fpm found"
  fi
  [ "$any" = 1 ] || emit "  nothing to do"
  PLAN_ANY=$any
  return 0
}

confirm() {
  local answer
  [ "$ASSUME_YES" = 1 ] && return 0
  if ! { exec 8</dev/tty; } 2>/dev/null; then
    echo "no terminal to ask for confirmation, re-run with --yes to proceed without asking" >&2
    return 1
  fi
  printf 'Proceed with the plan above? [y/N] ' >/dev/tty
  read -r answer <&8
  exec 8<&-
  case "$answer" in
    y|Y|yes|YES|t|T|tak|TAK) return 0 ;;
  esac
  return 1
}

keep_conn_files() {
  grep -rlsE '^[^#]*\<fastcgi_keep_conn[[:space:]]+on[[:space:]]*;' $NGINX_DIRS 2>/dev/null | sort -u
}

reuse_files() {
  grep -rlsiE '^[^#]*enablereuse=on' $APACHE_DIRS 2>/dev/null | sort -u
}

catch_output_files() {
  grep -rlsiE '^[[:space:]]*catch_workers_output[[:space:]]*=[[:space:]]*(yes|on|1|true)' $FPM_POOL_DIRS 2>/dev/null | grep -E '\.conf$' | sort -u
}

upload_progress_on() {
  timeout 10 "$1" -i 2>/dev/null </dev/null | grep -qE '^session\.upload_progress\.enabled => On'
}

unpatched_branches() {
  local entry ver
  for entry in "${UNPATCHED[@]:-}"; do
    [ -n "$entry" ] || continue
    case "${entry%%|*}" in */frankenphp) continue ;; esac
    ver=${entry##*|}
    [ -n "$ver" ] && echo "${ver%.*}"
  done | sort -u
}

print_exposure() {
  local f entry bin
  [ "${#UNPATCHED[@]}" -gt 0 ] && [ -n "${UNPATCHED[0]}" ] || return 0
  emit "--- exposure while PHP is unpatched (fix with --mitigate) ---"
  while read -r f; do
    [ -n "$f" ] && emit "EXPOSED    nginx fastcgi_keep_conn on (FPM request smuggling): $f"
  done <<<"$(keep_conn_files)"
  while read -r f; do
    [ -n "$f" ] && emit "EXPOSED    apache enablereuse=on (FPM request smuggling): $f"
  done <<<"$(reuse_files)"
  for entry in "${UNPATCHED[@]}"; do
    bin=${entry%%|*}
    case "$bin" in */frankenphp) continue ;; esac
    upload_progress_on "$bin" && emit "EXPOSED    session.upload_progress.enabled=On (session RCE): $bin"
  done
  while read -r f; do
    [ -n "$f" ] && emit "INFO       catch_workers_output=yes (FPM local privilege escalation, change by hand if the master runs as root): $f"
  done <<<"$(catch_output_files)"
}

backup_file() {
  mkdir -p "$BACKUP_DIR"
  cp -a --parents "$1" "$BACKUP_DIR/"
}

restore_files() {
  local f
  while read -r f; do
    [ -n "$f" ] && cp -a "$BACKUP_DIR$f" "$f"
  done <<<"$1"
}

reload_unit() {
  [ "$RESTART" = 1 ] || { log "--no-restart: reload $1 yourself"; return 0; }
  systemctl is-active -q "$1" 2>/dev/null || return 0
  log "reload $1"
  systemctl reload "$1" || log "ERROR: reload of $1 failed"
}

mitigate_nginx() {
  local files f
  files=$(keep_conn_files)
  [ -n "$files" ] || return 0
  while read -r f; do
    backup_file "$f"
    sed -i -E ':a; s/^([^#]*\<fastcgi_keep_conn[[:space:]]+)on([[:space:]]*;)/\1off\2/; ta' "$f"
    log "fastcgi_keep_conn off: $f (backup: $BACKUP_DIR$f)"
  done <<<"$files"
  if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
    restore_files "$files"
    log "ERROR: nginx -t failed after the change, the files were restored"
    return 1
  fi
  reload_unit nginx
}

apache_configtest() {
  local ctl
  for ctl in apache2ctl apachectl; do
    command -v "$ctl" >/dev/null 2>&1 || continue
    "$ctl" -t >/dev/null 2>&1
    return
  done
  return 0
}

mitigate_apache() {
  local files f
  files=$(reuse_files)
  [ -n "$files" ] || return 0
  while read -r f; do
    backup_file "$f"
    sed -i -E 's/(enablereuse=)on/\1off/I' "$f"
    log "enablereuse=off: $f (backup: $BACKUP_DIR$f)"
  done <<<"$files"
  if ! apache_configtest; then
    restore_files "$files"
    log "ERROR: apache configtest failed after the change, the files were restored"
    return 1
  fi
  reload_unit apache2
  reload_unit httpd
}

mitigate_php_ini() {
  local branch sapi dir ini content
  for branch in $(unpatched_branches); do
    content="session.upload_progress.enabled = 0"
    [ "$branch" = 8.5 ] && content+=$'\n'"fatal_error_backtraces = 0"
    for sapi in fpm cgi apache2; do
      dir=$PHP_ETC/$branch/$sapi/conf.d
      [ -d "$dir" ] || continue
      ini=$dir/$MITIGATION_INI
      [ "$(cat "$ini" 2>/dev/null)" = "$content" ] && continue
      echo "$content" >"$ini"
      log "wrote $ini"
      CHANGED=1
      [ "$sapi" = apache2 ] && APACHE_RESTART=1
    done
    [ -d "$PHP_ETC/$branch" ] || log "WARNING: no $PHP_ETC/$branch, set session.upload_progress.enabled=0 in the php.ini of PHP $branch by hand"
  done
}

remove_mitigation_ini() {
  local f branch
  for f in "$PHP_ETC"/*/*/conf.d/"$MITIGATION_INI"; do
    [ -f "$f" ] || continue
    branch=${f#"$PHP_ETC"/}
    branch=${branch%%/*}
    unpatched_branches | grep -qx "$branch" && continue
    rm -f "$f"
    log "PHP $branch is patched, removed $f"
  done
}

apply_mitigations() {
  log "--- mitigations ---"
  mitigate_nginx
  mitigate_apache
  mitigate_php_ini
}

ondrej_ppa_in_use() {
  grep -rlqE 'ondrej/php|ondrej-php' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null
}

sury_repo_present() {
  grep -rlqE 'packages\.sury\.org' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null
}

sury_fixed_revision() {
  case "$1" in
    5.6) echo 5.6.40-108 ;;
    7.0) echo 7.0.33-96 ;;
    7.1) echo 7.1.33-84 ;;
    7.2) echo 7.2.34-69 ;;
    7.3) echo 7.3.33-40 ;;
    7.4) echo 7.4.33-36 ;;
    8.0) echo 8.0.30-30 ;;
    8.1) echo 8.1.34-13 ;;
  esac
}

candidate_is_fixed() {
  local cand=${1#*:} up branch fixed
  up=${cand%%-*}
  branch=$(echo "$up" | cut -d. -f1,2)
  fixed=$(min_fixed "$branch")
  if [ -n "$fixed" ]; then
    version_ge "$up" "$fixed"
    return
  fi
  fixed=$(sury_fixed_revision "$branch")
  [ -n "$fixed" ] && dpkg --compare-versions "$cand" ge "$fixed"
}

needs_sury_switch() {
  local entry bin pkg cand found=1
  for entry in "${UNPATCHED[@]:-}"; do
    [ -n "$entry" ] || continue
    bin=${entry%%|*}
    pkg=$(binary_owner "$bin")
    [ -n "$pkg" ] || continue
    installed_version "$pkg" | grep -qi 'sury' || continue
    cand=$(package_candidate "$pkg")
    [ -n "$cand" ] && [ "$cand" != "(none)" ] || continue
    candidate_is_fixed "$cand" && continue
    if sury_has_fix "$pkg"; then
      found=0
    else
      log "packages.sury.org ($(sury_codename)) has no fixed $pkg yet either"
    fi
  done
  [ "$found" = 0 ] || log "staying on the ondrej/php PPA: switching would not bring a fix"
  return "$found"
}

switch_to_sury() {
  local codename f moved=() list=/etc/apt/sources.list.d/php-sury.list
  codename=$(lsb_release -sc 2>/dev/null)
  if [ -z "$codename" ]; then
    apt-get install -y -qq lsb-release >/dev/null 2>&1
    codename=$(lsb_release -sc 2>/dev/null)
  fi
  [ -n "$codename" ] || { log "ERROR: cannot determine the distribution codename, switch the repository manually"; return 1; }
  curl -fsI -m 30 "https://packages.sury.org/php/dists/$codename/InRelease" >/dev/null 2>&1 \
    || { log "ERROR: packages.sury.org has no '$codename' distribution, keeping the current repository"; return 1; }
  log "the ondrej/php PPA has no fix yet, switching to packages.sury.org ($codename)"
  apt-get install -y -qq ca-certificates curl >/dev/null 2>&1
  curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/debsuryorg-archive-keyring.deb >/dev/null \
    || { log "ERROR: could not install the packages.sury.org keyring"; return 1; }
  mkdir -p "$BACKUP_DIR/apt"
  for f in $(grep -rlE 'ondrej/php|ondrej-php' /etc/apt/sources.list.d 2>/dev/null); do
    mv "$f" "$BACKUP_DIR/apt/" && moved+=("$f")
    log "disabled old PHP source: $f (backup: $BACKUP_DIR/apt/)"
  done
  if grep -qE 'ondrej/php|ondrej-php' /etc/apt/sources.list 2>/dev/null; then
    cp -a /etc/apt/sources.list "$BACKUP_DIR/apt/sources.list"
    sed -i -E '/ondrej\/php|ondrej-php/s/^/#/' /etc/apt/sources.list
    log "commented out ondrej/php in /etc/apt/sources.list"
  fi
  echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $codename main" >"$list"
  apt-get update -qq || log "ERROR: apt-get update after switching repositories"
  if apt-cache policy 2>/dev/null | grep -q 'packages.sury.org'; then
    log "packages.sury.org is active"
    return 0
  fi
  log "ERROR: packages.sury.org is not visible to apt, restoring the old sources"
  rm -f "$list"
  for f in "${moved[@]:-}"; do
    [ -n "$f" ] && mv "$BACKUP_DIR/apt/$(basename "$f")" "$f"
  done
  [ -f "$BACKUP_DIR/apt/sources.list" ] && cp -a "$BACKUP_DIR/apt/sources.list" /etc/apt/sources.list
  apt-get update -qq
  return 1
}

ppa_built_packages() {
  dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | awk '/deb\.sury\.org\+1/ {print $1}' | grep -E '^(php[0-9]+\.[0-9]+(-|$)|libapache2-mod-php[0-9]+\.[0-9]+$)'
}

align_to_sury() {
  local p v cur args=()
  for p in $(ppa_built_packages); do
    v=$(sury_version "$p")
    [ -n "$v" ] || continue
    cur=$(installed_version "$p")
    [ "$v" != "$cur" ] || continue
    if dpkg --compare-versions "$(upstream_version "$v")" lt "$(upstream_version "$cur")"; then
      log "keeping $p $cur from the ondrej/php PPA, packages.sury.org has only the older $v"
      continue
    fi
    args+=("$p=$v")
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  log "moving ${#args[@]} PHP packages to the packages.sury.org builds (details: $LOG)"
  DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y -qq --allow-downgrades \
    -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "${args[@]}" \
    || log "ERROR: moving packages to packages.sury.org failed"
}

refresh_package_lists() {
  log "apt-get update"
  apt-get update -qq -o Acquire::Retries=2 -o Acquire::https::Timeout=30 -o Acquire::http::Timeout=30 >/dev/null || log "ERROR: apt-get update"
  APT_UPDATED=1
}

apt_upgrade_php() {
  DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y -qq --only-upgrade \
    -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef $1
}

update_packages() {
  local pkgs held switched=0
  pkgs=$(php_package_snapshot | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ -z "${pkgs// /}" ]; then
    log "no PHP packages installed via apt"
    return 0
  fi
  held=$(apt-mark showhold 2>/dev/null | grep -E '^php|^libapache2-mod-php|^hestia-php' | tr '\n' ' ')
  [ -n "$held" ] && log "WARNING: PHP packages on hold, they will not be upgraded: $held"
  [ "$APT_UPDATED" = 1 ] || refresh_package_lists
  if [ "$SWITCH_REPO" = 1 ] && ondrej_ppa_in_use && ! sury_repo_present; then
    print_report quiet
    needs_sury_switch && switch_to_sury && switched=1
  fi
  [ "$switched" = 1 ] && align_to_sury
  log "apt-get install --only-upgrade (details: $LOG): $pkgs"
  apt_upgrade_php "$pkgs" && return 0
  log "ERROR: apt-get install --only-upgrade"
  if [ "$switched" = 0 ] && [ "$SWITCH_REPO" = 1 ] && ondrej_ppa_in_use && ! sury_repo_present; then
    log "the PPA could not deliver the packages, switching to packages.sury.org and retrying"
    if switch_to_sury; then
      align_to_sury
      log "apt-get install --only-upgrade (retry): $pkgs"
      apt_upgrade_php "$pkgs" || log "ERROR: apt-get install --only-upgrade (retry)"
    fi
  fi
}

restart_unit() {
  log "restart $1"
  systemctl restart "$1" || log "ERROR: restart of $1 failed"
  systemctl is-active -q "$1" || log "CRITICAL: $1 is not running after restart, check: journalctl -u $1 -n 50"
}

FPM_UNIT_RE='^php.*fpm.*\.service$|^hestia\.service$|^frankenphp\.service$'

fpm_master_pids() {
  local p cmd
  for p in /proc/[0-9]*; do
    cmd=$(proc_cmdline "${p#/proc/}")
    case "$cmd" in
      "php-fpm: master process"*) echo "${p#/proc/}" ;;
    esac
  done
}

pid_unit() {
  sed -n 's#^.*/\([^/]*\.service\)$#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n1
}

pid_in_container() {
  grep -qE 'docker|containerd|lxc|libpod|kubepods' "/proc/$1/cgroup" 2>/dev/null
}

supervisor_program_of() {
  local pid=$1 prog
  command -v supervisorctl >/dev/null 2>&1 || return 0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    prog=$(supervisorctl status 2>/dev/null | awk -v pid="$pid" '$2 == "RUNNING" && $4 == pid"," {print $1; exit}')
    if [ -n "$prog" ]; then
      echo "$prog"
      return 0
    fi
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
  done
}

fpm_targets() {
  local pid unit prog
  {
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -E "$FPM_UNIT_RE" | sed 's/^/unit /'
    fi
    for pid in $(fpm_master_pids); do
      if pid_in_container "$pid"; then
        echo "container $pid"
        continue
      fi
      unit=$(pid_unit "$pid")
      if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1 \
          && { echo "$unit" | grep -qE "$FPM_UNIT_RE" || [ "$(systemctl show -p MainPID --value "$unit" 2>/dev/null)" = "$pid" ]; }; then
        echo "unit $unit"
        continue
      fi
      prog=$(supervisor_program_of "$pid")
      if [ -n "$prog" ]; then
        echo "supervisor $prog"
      else
        echo "signal $pid"
      fi
    done
  } | sort -u
}

describe_fpm_targets() {
  local kind name
  while read -r kind name; do
    case "$kind" in
      unit) echo "systemctl restart $name" ;;
      supervisor) echo "supervisorctl restart $name" ;;
      signal) echo "kill -USR2 $name (php-fpm master outside systemd/supervisor: $(proc_cmdline "$name" | cut -c1-80))" ;;
      container) echo "skip php-fpm master $name: it runs in a container, rebuild/restart the container yourself" ;;
    esac
  done <<<"$(fpm_targets)"
}

restart_services() {
  local kind name
  while read -r kind name; do
    case "$kind" in
      unit) restart_unit "$name" ;;
      supervisor)
        log "restart supervisor program $name"
        supervisorctl restart "$name" >/dev/null || log "ERROR: restart of supervisor program $name failed" ;;
      signal)
        log "php-fpm master $name is not managed by systemd or supervisor, sending USR2 (re-exec with the new binary, empties OPcache)"
        kill -USR2 "$name" || log "ERROR: kill -USR2 $name failed, restart this php-fpm by hand" ;;
      container)
        log "php-fpm master $name runs in a container, restart the container yourself" ;;
    esac
  done <<<"$(fpm_targets)"
  if [ "$APACHE_RESTART" = 1 ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active -q apache2 2>/dev/null; then
    restart_unit apache2
  fi
}

print_fpm_masters() {
  local pid exe ver
  for pid in $(fpm_master_pids); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    case "$exe" in
      *"(deleted)") ver="OLD BINARY (deleted), not restarted" ;;
      *) ver="PHP $(binary_version "$exe")" ;;
    esac
    emit "FPM        master pid $pid ${exe:-?} $ver unit=$(pid_unit "$pid")"
  done
}

stale_processes() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in
      *php*"(deleted)") ;;
      *) grep -qE '/libphp[0-9.]*\.so \(deleted\)$' "$p/maps" 2>/dev/null || continue ;;
    esac
    echo "${p#/proc/} $(proc_cmdline "${p#/proc/}" | cut -c1-110)"
  done
}

main() {
  local arg before after stale status entry

  for arg in "$@"; do
    case "$arg" in
      --check) MODE=check ;;
      --apply) MODE=apply ;;
      --mitigate) MITIGATE=1 ;;
      --no-switch-repo) SWITCH_REPO=0 ;;
      --no-build-source) BUILD_SOURCE=0 ;;
      --no-restart) RESTART=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  exec </dev/null
  trap 'rm -f "$SURY_INDEX"' EXIT

  if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    echo "this script supports Debian/Ubuntu only (dpkg + apt-get)" >&2
    exit 2
  fi

  if [ "$MODE" = apply ] || [ "$MITIGATE" = 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
      echo "--apply and --mitigate need root (run: sudo bash -s -- --apply)" >&2
      exit 2
    fi
    if command -v flock >/dev/null 2>&1; then
      exec 9>/var/lock/php-smuggling-fix.lock
      flock -n 9 || { echo "the script is already running on this server" >&2; exit 2; }
    fi
  fi

  [ "$(id -u)" -eq 0 ] || log "WARNING: not running as root, the report may be incomplete"
  log "php-smuggling-fix v$VERSION host=$(hostname) mode=$MODE mitigate=$MITIGATE (${CVES[*]})"
  [ "$MODE" = apply ] && refresh_package_lists
  log "--- state before ---"
  print_report
  for entry in "${!REPORT[@]}"; do
    BEFORE[$entry]=${REPORT[$entry]}
  done

  if [ $((OK + BAD + MANUAL)) -eq 0 ]; then
    log "no PHP found on this server, exiting"
    echo "RESULT host=$(hostname) status=NOPHP patched=0 vulnerable=0 manual=0 changed=0"
    exit 0
  fi

  print_exposure
  print_fpm_masters
  print_plan

  if [ "$MODE" = check ] && [ "$MITIGATE" = 0 ]; then
    log "check mode: nothing was changed, run with --apply (and --mitigate) to carry out the plan"
  elif [ "$PLAN_ANY" = 1 ]; then
    if ! confirm; then
      log "aborted, nothing was changed"
      echo "RESULT host=$(hostname) status=ABORTED patched=$OK vulnerable=$BAD manual=$MANUAL changed=0"
      exit 3
    fi
  fi

  if [ "$MODE" = apply ]; then
    before=$(php_package_snapshot)
    update_packages
    after=$(php_package_snapshot)
    if [ "$before" != "$after" ]; then
      CHANGED=1
      diff <(echo "$before") <(echo "$after") | grep -q '^> libapache2-mod-php' && APACHE_RESTART=1
    fi

    if [ "$BUILD_SOURCE" = 1 ]; then
      print_report quiet
      build_source_release
    fi
    print_report quiet
  fi

  if [ "$MITIGATE" = 1 ]; then
    apply_mitigations
    remove_mitigation_ini
  fi

  if [ "$MODE" = apply ] || [ "$MITIGATE" = 1 ]; then
    stale=$(stale_processes)
    if [ "$RESTART" = 1 ] && { [ "$CHANGED" = 1 ] || [ -n "$stale" ]; }; then
      restart_services
      sleep 3
    fi
    log "--- state after ---"
    print_report
    print_exposure
    print_fpm_masters
    print_summary
  fi

  for entry in "${UNPATCHED[@]:-}"; do
    case "${entry%%|*}" in
      */frankenphp)
        log "FrankenPHP bundles PHP ${entry##*|}: ${entry%%|*} (system PHP upgrades do not change it). Update it with: curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/$REPO_TAG/frankenphp-update.sh | sudo bash -s -- ${entry%%|*}" ;;
    esac
  done

  stale=$(stale_processes)
  if [ -n "$stale" ]; then
    log "PROCESSES STILL ON THE OLD BINARY (restart queue workers / supervisor):"
    echo "$stale"
  fi

  if [ $((BAD + MANUAL)) -gt 0 ] && [ "$MITIGATE" = 0 ]; then
    log "some PHP binaries are still unpatched, re-run with --mitigate to turn off FastCGI connection reuse and session upload progress"
  fi

  if [ "$BAD" -gt 0 ]; then
    status=VULNERABLE
  elif [ "$MANUAL" -gt 0 ]; then
    status=MANUAL
  elif [ -n "$stale" ]; then
    status=STALE
  else
    status=OK
  fi
  echo "RESULT host=$(hostname) status=$status patched=$OK vulnerable=$BAD manual=$MANUAL changed=$CHANGED"
  case "$status" in
    OK) exit 0 ;;
    *) exit 1 ;;
  esac
}

if [ -z "${PHP_SMUGGLING_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
