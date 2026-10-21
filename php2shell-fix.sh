#!/usr/bin/env bash
set -u
export LC_ALL=C

VERSION=1.0
CVES=(CVE-2026-109618 CVE-2026-109619)
MODE=check
RESTART=1
SWITCH_REPO=1
BUILD_SOURCE=1
CHANGED=0
MARKER_DIR=/var/lib/php2shell
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=/var/log/php2shell-fix.log
BACKUP_DIR=/root/php2shell-backup-$STAMP
PHP_DEB_RE='^(php[0-9]+\.[0-9]+(-[^ ]+)?|hestia-php|frankenphp) '

usage() {
  cat <<EOF
Usage: php2shell-fix.sh [options]   (from the network: curl -fsSL <URL> | sudo bash -s -- [options])
  --check            report only, no changes (default)
  --apply            upgrade PHP packages, build source-installed PHP 7.4/8.0/8.1, restart php-fpm (needs root)
  --no-switch-repo   with --apply: do not switch from the ondrej/php PPA to packages.sury.org when the PPA has no fix yet
  --no-build-source  with --apply: do not build package-less PHP 7.4/8.0/8.1 from source (release tag + fix from github.com/php/php-src)
  --no-restart       with --apply: do not restart services
  -h, --help         this help
Exit code: 0 = everything patched or no PHP found, 1 = vulnerable binaries left or processes still on the old binary
Last line: RESULT host=... status=OK|NOPHP|STALE|VULNERABLE|MANUAL changed=0|1
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
    8.2) echo 8.2.35 ;;
    8.3) echo 8.3.36 ;;
    8.4) echo 8.4.27 ;;
    8.5) echo 8.5.12 ;;
  esac
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
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
  timeout 10 "$1" $arg 2>/dev/null </dev/null | grep -oE -m1 'PHP [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2
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

backport_sha() {
  case "$1" in
    7.4) echo 712e60f9edfd03f0960fc4fc3c2c375f42b90aa2 ;;
    8.0) echo 82f8f31b16a035c1b67cc253e79f7cc288f4cc20 ;;
    8.1) echo 1d7dec178a094e6e75b229ce22754045f8c6070a ;;
  esac
}

backport_tag() {
  case "$1" in
    7.4) echo php-7.4.33 ;;
    8.0) echo php-8.0.30 ;;
    8.1) echo php-8.1.34 ;;
  esac
}

binary_hash() {
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
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
  'with-imap=libc-client-dev'
  'with-kerberos|with-imap-ssl=libkrb5-dev'
  'with-tidy=libtidy-dev'
  'with-ffi=libffi-dev'
  'with-fpm-systemd=libsystemd-dev'
  'with-apxs2=apache2-dev'
  'with-enchant=libenchant-2-dev/libenchant-dev'
  'with-snmp=libsnmp-dev'
  'with-pspell=libpspell-dev'
  'with-unixODBC|with-pdo-odbc=unixodbc-dev'
)

package_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

build_dep_packages() {
  local cmd=$1 entry regex alts alt
  echo "build-essential autoconf automake libtool bison re2c pkg-config curl tar patch ca-certificates libxml2-dev libsqlite3-dev" | tr ' ' '\n'
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
      3*) log "ERROR: PHP $branch does not support OpenSSL $sslver (this system) and cannot be built here, use the Sury PHP packages or an older OS"; return 1 ;;
    esac
  fi
  return 0
}

build_and_install() {
  local branch=$1 sha=$2 cmd=$3 binlist=$4 dir prefix jobs tool b after
  local -A before=()
  ensure_build_deps "$branch" "$cmd" || return 1
  for tool in gcc make autoconf bison re2c curl tar patch; do
    command -v "$tool" >/dev/null 2>&1 || { log "ERROR: '$tool' is still missing after installation, skipping the PHP $branch build"; return 1; }
  done
  dir=/usr/local/src/php2shell-$branch-$STAMP
  jobs=$(nproc 2>/dev/null || echo 2)
  [ "$jobs" -gt 4 ] && jobs=4
  mkdir -p "$dir"
  log "building PHP $branch: $(backport_tag "$branch") + php-src fix @$sha (log: $dir.log)"
  (
    set -e
    set -o pipefail
    cd "$dir"
    curl -fsSL "https://github.com/php/php-src/archive/refs/tags/$(backport_tag "$branch").tar.gz" | tar xz --strip-components=1
    curl -fsSL "https://github.com/php/php-src/commit/$sha.patch" | patch -p1
    grep -q zend_mm_safe_error_ex Zend/zend_alloc.c
    ./buildconf --force
    eval "set -- $cmd"
    shift
    ./configure "$@"
    nice -n 19 make -j"$jobs"
    sapi/cli/php -v | grep -q "^PHP $branch\."
  ) >"$dir.log" 2>&1 </dev/null || { log "ERROR: building PHP $branch failed, old binaries untouched, log: $dir.log"; return 1; }
  prefix=$(echo "$cmd" | grep -oE "'--prefix=[^']*'" | head -n1 | cut -d= -f2 | tr -d "'")
  prefix=${prefix:-/usr/local}
  while read -r b; do
    [ -n "$b" ] && before[$b]=$(binary_hash "$b")
  done <<<"$binlist"
  mkdir -p "$BACKUP_DIR"
  tar czf "$BACKUP_DIR/php-$branch-$(echo "$prefix" | tr / _).tgz" -C "$prefix" $(cd "$prefix" && ls -d bin sbin 2>/dev/null) 2>/dev/null
  echo "$cmd" | grep -q 'apxs' && log "WARNING: PHP $branch has mod_php (apxs), make install may modify the Apache configuration"
  (cd "$dir" && make install) >>"$dir.log" 2>&1 </dev/null || { log "ERROR: make install for PHP $branch failed, log: $dir.log, backup: $BACKUP_DIR"; return 1; }
  CHANGED=1
  while read -r b; do
    [ -n "$b" ] || continue
    after=$(binary_hash "$b")
    if [ "$after" != "${before[$b]:-}" ] && [ "$(binary_version "$b" | cut -d. -f1,2)" = "$branch" ]; then
      mark_source_build "$b" "$sha"
      log "installed patched PHP $branch: $b (backup of old binaries: $BACKUP_DIR)"
    else
      log "WARNING: $b did not change after make install, check that the prefix ($prefix) is correct"
    fi
  done <<<"$binlist"
  rm -rf "$dir"
  return 0
}

build_source_backport() {
  local entry bin ver branch sha cmd key
  local -a keys=()
  local -A bins=() meta=()
  for entry in "${UNPATCHED[@]:-}"; do
    [ -n "$entry" ] || continue
    bin=${entry%%|*}
    ver=${entry##*|}
    [ -n "$ver" ] || continue
    branch=${ver%.*}
    sha=$(backport_sha "$branch")
    [ -n "$sha" ] || continue
    [ -z "$(binary_owner "$bin")" ] || continue
    cmd=$(timeout 10 "$bin" -i 2>/dev/null </dev/null | sed -n 's/^Configure Command => *//p' | head -n1)
    if [ -z "$cmd" ]; then
      log "ERROR: cannot read the Configure Command from $bin, build it manually"
      continue
    fi
    key="$sha $cmd"
    if [ -z "${meta[$key]:-}" ]; then
      keys+=("$key")
      meta[$key]="$branch"$'\t'"$sha"$'\t'"$cmd"
    fi
    bins[$key]+="$bin"$'\n'
  done
  for key in "${keys[@]:-}"; do
    [ -n "$key" ] || continue
    IFS=$'\t' read -r branch sha cmd <<<"${meta[$key]}"
    build_and_install "$branch" "$sha" "$cmd" "${bins[$key]}"
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
  elif version_ge "$branch" 8.6; then
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

print_report() {
  local quiet=${1:-} bin line state ver pkg
  OK=0
  BAD=0
  MANUAL=0
  UNPATCHED=()
  [ -n "$quiet" ] || emit "$(printf '%-10s %-9s %-28s %s' STATE VERSION PACKAGE BINARY)"
  while read -r bin; do
    [ -n "$bin" ] || continue
    line=$(assess_binary "$bin" </dev/null)
    state=${line%%|*}
    [ "$state" = SKIP ] && continue
    ver=$(echo "$line" | cut -d'|' -f2)
    pkg=$(echo "$line" | cut -d'|' -f3)
    [ -n "$quiet" ] || emit "$(printf '%-10s %-9s %-28s %s' "$state" "${ver:--}" "${pkg:--}" "$bin")"
    case "$state" in
      PATCHED) OK=$((OK+1)) ;;
      SOURCE|UNKNOWN) MANUAL=$((MANUAL+1)); UNPATCHED+=("$bin|$ver") ;;
      VULNERABLE) BAD=$((BAD+1)); UNPATCHED+=("$bin|$ver") ;;
    esac
  done < <(collect_binaries)
}

ondrej_ppa_in_use() {
  grep -rlqE 'ondrej/php|ondrej-php' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null
}

sury_repo_present() {
  grep -rlqE 'packages\.sury\.org' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null
}

needs_sury_switch() {
  local entry bin pkg cand up branch fixed
  for entry in "${UNPATCHED[@]:-}"; do
    [ -n "$entry" ] || continue
    bin=${entry%%|*}
    pkg=$(binary_owner "$bin")
    [ -n "$pkg" ] || continue
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null | grep -qi 'sury' || continue
    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')
    [ -n "$cand" ] && [ "$cand" != "(none)" ] || continue
    up=${cand#*:}
    up=${up%%-*}
    branch=${up%.*}
    fixed=$(min_fixed "$branch")
    if [ -z "$fixed" ] || ! version_ge "$up" "$fixed"; then
      return 0
    fi
  done
  return 1
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

update_packages() {
  local pkgs held
  pkgs=$(php_package_snapshot | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ -z "${pkgs// /}" ]; then
    log "no PHP packages installed via apt"
    return 0
  fi
  held=$(apt-mark showhold 2>/dev/null | grep -E '^php|^hestia-php' | tr '\n' ' ')
  [ -n "$held" ] && log "WARNING: PHP packages on hold, they will not be upgraded: $held"
  log "apt-get update"
  apt-get update -qq || log "ERROR: apt-get update"
  if [ "$SWITCH_REPO" = 1 ] && ondrej_ppa_in_use && ! sury_repo_present; then
    print_report quiet
    needs_sury_switch && switch_to_sury
  fi
  log "apt-get install --only-upgrade: $pkgs"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef $pkgs \
    || log "ERROR: apt-get install --only-upgrade"
}

restart_unit() {
  log "restart $1"
  systemctl restart "$1" || log "ERROR: restart of $1 failed"
  systemctl is-active -q "$1" || log "CRITICAL: $1 is not running after restart, check: journalctl -u $1 -n 50"
}

restart_services() {
  local unit
  command -v systemctl >/dev/null 2>&1 || { log "systemctl not found, restart PHP manually"; return 1; }
  for unit in $(systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null \
      | awk '{print $1}' | grep -E '^php.*fpm.*\.service$|^hestia\.service$|^frankenphp\.service$'); do
    restart_unit "$unit"
  done
}

stale_processes() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in
      *php*"(deleted)")
        echo "${p#/proc/} $(tr '\0' ' ' <"$p/cmdline" 2>/dev/null | cut -c1-110)" ;;
    esac
  done
}

main() {
  local arg before after stale status entry

  for arg in "$@"; do
    case "$arg" in
      --check) MODE=check ;;
      --apply) MODE=apply ;;
      --no-switch-repo) SWITCH_REPO=0 ;;
      --no-build-source) BUILD_SOURCE=0 ;;
      --no-restart) RESTART=0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  exec </dev/null

  if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    echo "this script supports Debian/Ubuntu only (dpkg + apt-get)" >&2
    exit 2
  fi

  if [ "$MODE" = apply ]; then
    if [ "$(id -u)" -ne 0 ]; then
      echo "--apply needs root (run: sudo bash -s -- --apply)" >&2
      exit 2
    fi
    if command -v flock >/dev/null 2>&1; then
      exec 9>/var/lock/php2shell-fix.lock
      flock -n 9 || { echo "the script is already running on this server" >&2; exit 2; }
    fi
  fi

  [ "$(id -u)" -eq 0 ] || log "WARNING: not running as root, the report may be incomplete"
  log "php2shell-fix v$VERSION host=$(hostname) mode=$MODE"
  log "--- state before ---"
  print_report

  if [ $((OK + BAD + MANUAL)) -eq 0 ]; then
    log "no PHP found on this server, exiting"
    echo "RESULT host=$(hostname) status=NOPHP patched=0 vulnerable=0 manual=0 changed=0"
    exit 0
  fi

  if [ "$MODE" = apply ]; then
    before=$(php_package_snapshot)
    update_packages
    after=$(php_package_snapshot)
    [ "$before" != "$after" ] && CHANGED=1

    if [ "$BUILD_SOURCE" = 1 ]; then
      print_report quiet
      build_source_backport
    fi

    stale=$(stale_processes)
    if [ "$RESTART" = 1 ] && { [ "$CHANGED" = 1 ] || [ -n "$stale" ]; }; then
      restart_services
      sleep 3
    fi
    log "--- state after ---"
    print_report
  fi

  for entry in "${UNPATCHED[@]:-}"; do
    case "${entry%%|*}" in
      */frankenphp)
        log "FrankenPHP bundles PHP ${entry##*|}: ${entry%%|*} (upgrading system PHP does not change it, it needs a FrankenPHP release with fixed PHP or a new image)" ;;
    esac
  done

  stale=$(stale_processes)
  if [ -n "$stale" ]; then
    log "PROCESSES STILL ON THE OLD BINARY (restart queue workers / supervisor):"
    echo "$stale"
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

if [ -z "${PHP2SHELL_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
