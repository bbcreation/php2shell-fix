#!/usr/bin/env bash
set -u

SCRIPT=${1:-$(dirname "$0")/../php-smuggling-fix.sh}
FAIL=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export LOG=$T/log BACKUP_DIR=$T/backup
export MARKER_DIR=$T/markers
export NGINX_DIRS=$T/nginx APACHE_DIRS=$T/apache FPM_POOL_DIRS=$T/php PHP_ETC=$T/php
export PHP_SMUGGLING_SOURCE_ONLY=1 PHP2SHELL_SOURCE_ONLY=1
. "$SCRIPT"
RESTART=0

ok() {
  if "$@"; then echo "ok   $*"; else echo "FAIL $*"; FAIL=1; fi
}

not() {
  ! "$@"
}

fixed() {
  version_ge "$1" "$(min_fixed "${1%.*}")"
}

fake_php() {
  printf '#!/bin/sh\necho "%s"\n' "$2" >"$T/$1"
  chmod +x "$T/$1"
  echo "$T/$1"
}

ok not fixed 8.2.35
ok fixed 8.2.36
ok not fixed 8.3.36
ok fixed 8.3.37
ok not fixed 8.4.27
ok fixed 8.4.28
ok not fixed 8.5.12
ok fixed 8.5.13
ok fixed 8.5.14-dev
ok not fixed 8.5.13-dev
ok not fixed 8.6.0RC7
ok fixed 8.6.0

ok not candidate_is_fixed 8.4.27-1+0~20261021.1+debian12~1.gbp
ok candidate_is_fixed 8.4.28-2+0~deb.sury.org.1+debian12
ok not candidate_is_fixed 8.6.0~rc7-1+0~deb.sury.org.1+debian12
ok not candidate_is_fixed 8.1.34-9+debsuryorg12.1+php+1
ok candidate_is_fixed 8.1.34-13+debsuryorg12.1+php+1
ok not candidate_is_fixed 1:7.4.33-31+debsuryorg12.1+php+1
ok candidate_is_fixed 1:7.4.33-37+debsuryorg12.1+php+1
ok candidate_is_fixed 1:8.0.30-30+debsuryorg12.1+php+1

ok [ "$(binary_version "$(fake_php php86 'PHP 8.6.0RC7 (cli) (built: Nov 1 2026)')")" = 8.6.0RC7 ]
ok [ "$(binary_version "$(fake_php php81 'PHP 8.1.2-1ubuntu2.22 (cli)')")" = 8.1.2 ]
ok [ "$(binary_version "$(fake_php php85 'PHP 8.5.14-dev (cli)')")" = 8.5.14-dev ]

mkdir -p "$T/nginx/sites-enabled" "$T/apache/sites-enabled" "$T/php/8.4/fpm/conf.d" "$T/php/8.4/fpm/pool.d" "$T/php/8.5/fpm/conf.d" "$T/php/8.3/fpm/conf.d"
printf 'location ~ \\.php$ {\n    fastcgi_keep_conn on;\n    # fastcgi_keep_conn on;\n}\n' >"$T/nginx/sites-enabled/a.conf"
printf 'location / {\n    fastcgi_keep_conn off;\n}\n' >"$T/nginx/sites-enabled/b.conf"
printf 'location ~ \\.php$ { fastcgi_pass 127.0.0.1:9000; fastcgi_keep_conn  on ; } location /x { fastcgi_keep_conn on; } # fastcgi_keep_conn on;\n' >"$T/nginx/sites-enabled/c.conf"
printf '<Proxy "fcgi://localhost" enablereuse=On max=10>\n</Proxy>\n' >"$T/apache/sites-enabled/a.conf"
printf '[www]\ncatch_workers_output = yes\n' >"$T/php/8.4/fpm/pool.d/www.conf"
echo old >"$T/php/8.3/fpm/conf.d/$MITIGATION_INI"

ok [ "$(keep_conn_files | tr '\n' ' ')" = "$T/nginx/sites-enabled/a.conf $T/nginx/sites-enabled/c.conf " ]
ok [ "$(reuse_files)" = "$T/apache/sites-enabled/a.conf" ]
ok [ "$(catch_output_files)" = "$T/php/8.4/fpm/pool.d/www.conf" ]

UNPATCHED=("/usr/sbin/php-fpm8.4|8.4.27" "/usr/sbin/php-fpm8.5|8.5.12" "$T/frankenphp|8.5.11")
ok [ "$(unpatched_branches | tr '\n' ' ')" = "8.4 8.5 " ]

mitigate_nginx >/dev/null
ok grep -q '^    fastcgi_keep_conn off;$' "$T/nginx/sites-enabled/a.conf"
ok grep -q '^    # fastcgi_keep_conn on;$' "$T/nginx/sites-enabled/a.conf"
ok [ -f "$T/backup$T/nginx/sites-enabled/a.conf" ]
ok [ "$(cat "$T/nginx/sites-enabled/c.conf")" = 'location ~ \.php$ { fastcgi_pass 127.0.0.1:9000; fastcgi_keep_conn  off ; } location /x { fastcgi_keep_conn off; } # fastcgi_keep_conn on;' ]
ok [ -z "$(keep_conn_files)" ]

mitigate_apache >/dev/null
ok grep -q 'enablereuse=off max=10' "$T/apache/sites-enabled/a.conf"
ok [ -z "$(reuse_files)" ]

mitigate_php_ini >/dev/null
ok [ "$(cat "$T/php/8.4/fpm/conf.d/$MITIGATION_INI")" = "session.upload_progress.enabled = 0" ]
ok grep -qx 'fatal_error_backtraces = 0' "$T/php/8.5/fpm/conf.d/$MITIGATION_INI"
ok [ "$CHANGED" = 1 ]

remove_mitigation_ini >/dev/null
ok [ ! -f "$T/php/8.3/fpm/conf.d/$MITIGATION_INI" ]
ok [ -f "$T/php/8.4/fpm/conf.d/$MITIGATION_INI" ]

ok [ "$(safe_version 8.4.27 sury)" = 8.4.28 ]
ok [ "$(safe_version 8.1.33 sury)" = 8.1.34-13 ]
ok [ "$(safe_version 7.4.33 ppa-ondrej)" = 7.4.33-36 ]
ok [ "$(safe_version 8.1.34 source)" = 8.1.34+sury ]
ok [ "$(safe_version 7.3.33 source)" = "none (EOL)" ]
ok [ "$(safe_version 8.1.2 distro)" = changelog:CVE-2026-129289 ]

printf 'Package: php8.0\nVersion: 1:8.0.30-31\n\nPackage: php8.1\nVersion: 8.1.34-14+debsuryorg12.1+php+1\nDirectory: pool/main/p/php8.1\nChecksums-Sha256:\n aaa 10 php8.1_8.1.34.orig.tar.xz\n bbb 20 php8.1_8.1.34-14+debsuryorg12.1+php+1.debian.tar.xz\nFiles:\n ccc 20 php8.1_8.1.34-14+debsuryorg12.1+php+1.debian.tar.xz\n' >"$T/Sources"
ok [ "$(sury_source_entry 8.1 <"$T/Sources")" = "8.1.34-14+debsuryorg12.1+php+1 pool/main/p/php8.1 php8.1_8.1.34-14+debsuryorg12.1+php+1.debian.tar.xz bbb" ]
ok [ -z "$(sury_source_entry 7.4 <"$T/Sources")" ]

mkdir -p "$T/eol81/bin" "$T/other"
printf '#!/bin/sh\ncase "$1" in -v) echo "PHP 8.1.34 (cli)";; -i) echo "Configure Command =>  '"'"'./configure'"'"'  '"'"'--prefix=%s'"'"' '"'"'--enable-fpm'"'"'";; esac\n' "$T/eol81" >"$T/eol81/bin/php"
chmod +x "$T/eol81/bin/php"
cp "$T/eol81/bin/php" "$T/other/php"
ok [ "$(source_build_target "$T/eol81/bin/php" 8.1.34 | cut -f1-3)" = "8.1	php-8.1.34	1" ]
ok not source_build_target "$T/other/php" 8.1.34
ok [ "$(binary_action "$T/eol81/bin/php" SOURCE 8.1.34 "")" = "build php-8.1.34 + the packages.sury.org security patches from source, install into $T/eol81 (takes 5-20 minutes)" ]
ok not source_build_marked "$T/eol81/bin/php"
mark_source_build "$T/eol81/bin/php" test
ok source_build_marked "$T/eol81/bin/php"
ok [ "$(assess_binary "$T/eol81/bin/php" | cut -d'|' -f1)" = PATCHED ]

ASSUME_YES=1
ok confirm
ASSUME_YES=0
ok not setsid -w bash -c ". '$SCRIPT'; ASSUME_YES=0; confirm" </dev/null 2>/dev/null

bash -c 'exec -a "php-fpm: master process (/etc/php/8.4/fpm/php-fpm.conf)" sleep 60' &
FPM_PID=$!
sleep 0.5
ok [ "$(fpm_master_pids)" = "$FPM_PID" ]
ok [ "$(fpm_targets)" = "signal $FPM_PID" ]
RESTART=1
restart_services >/dev/null
sleep 0.5
ok not kill -0 "$FPM_PID" 2>/dev/null

ok [ -z "$(proc_cmdline 999999999 2>&1)" ]

ppa_built_packages() { printf 'php8.4-fpm\nphp8.4-swoole\nphp8.4-redis\n'; }
installed_version() {
  case "$1" in
    php8.4-fpm) echo 8.4.27-1+ubuntu24.04.1+deb.sury.org+1 ;;
    php8.4-swoole) echo 6.2.3-1+ubuntu24.04.1+deb.sury.org+1 ;;
    php8.4-redis) echo 6.3.0-2+ubuntu24.04.1+deb.sury.org+1 ;;
  esac
}
sury_version() {
  case "$1" in
    php8.4-fpm) echo 8.4.28-2+0~deb.sury.org.1+ubuntu24.04 ;;
    php8.4-swoole) echo 6.2.0-1+0~20260622.46+ubuntu24.04~1.gbp801694 ;;
    php8.4-redis) echo 6.3.0-2+0~20260711.69+ubuntu24.04~1.gbpd148c3 ;;
  esac
}
apt-get() { echo "$*" >"$T/apt-args"; }
align_to_sury >"$T/align.log"
ok grep -q 'php8.4-fpm=8.4.28-2+0~deb.sury.org.1+ubuntu24.04' "$T/apt-args"
ok grep -q 'php8.4-redis=6.3.0-2+0~20260711.69+ubuntu24.04~1.gbpd148c3' "$T/apt-args"
ok not grep -q swoole "$T/apt-args"
ok grep -q 'keeping php8.4-swoole 6.2.3-1+ubuntu24.04.1+deb.sury.org+1' "$T/align.log"
unset -f apt-get ppa_built_packages sury_version

installed_version() { echo 8.4.27-1+ubuntu24.04.1+deb.sury.org+1; }
package_candidate() { echo 8.4.27-1+ubuntu24.04.1+deb.sury.org+1; }
ondrej_ppa_in_use() { return 0; }
sury_repo_present() { return 1; }
APT_UPDATED=0
ok [ "$(binary_action /usr/sbin/php-fpm8.4 VULNERABLE 8.4.27 php8.4-fpm)" = "no newer php8.4-fpm in the local package lists (--check does not run apt-get update); --apply refreshes them first and switches the ondrej/php PPA to packages.sury.org if it still has nothing newer" ]
APT_UPDATED=1
unset -f installed_version package_candidate ondrej_ppa_in_use sury_repo_present

unset BEFORE REPORT
declare -A BEFORE=(
  [/usr/sbin/php-fpm8.4]="VULNERABLE|8.4.27|php8.4-fpm|8.4.27-1+ubuntu24.04.1+deb.sury.org+1|ppa-ondrej"
  [/usr/bin/php8.3]="PATCHED|8.3.37|php8.3-cli|8.3.37-2|sury"
  [/usr/bin/php8.2]="VULNERABLE|8.2.35|php8.2-cli|8.2.35-1|distro"
  [/usr/local/php81/bin/php]="SOURCE|8.1.34|||source"
)
declare -A REPORT=(
  [/usr/sbin/php-fpm8.4]="PATCHED|8.4.28|php8.4-fpm|8.4.28-2+0~deb.sury.org.1+ubuntu24.04|sury"
  [/usr/bin/php8.3]="PATCHED|8.3.37|php8.3-cli|8.3.37-2|sury"
  [/usr/bin/php8.2]="VULNERABLE|8.2.35|php8.2-cli|8.2.35-1|distro"
  [/usr/local/php81/bin/php]="PATCHED|8.1.34|||source+sury"
)
print_summary >"$T/summary"
ok grep -qxF 'UPGRADED      /usr/sbin/php-fpm8.4: PHP 8.4.27 -> 8.4.28 (php8.4-fpm 8.4.27-1+ubuntu24.04.1+deb.sury.org+1 -> 8.4.28-2+0~deb.sury.org.1+ubuntu24.04, ppa-ondrej -> sury)' "$T/summary"
ok grep -qxF 'UPGRADED      /usr/local/php81/bin/php: PHP 8.1.34 -> 8.1.34 + packages.sury.org security patches (built from source)' "$T/summary"
ok grep -qxF 'ALREADY SAFE  /usr/bin/php8.3: PHP 8.3.37' "$T/summary"
ok grep -qxF 'STILL UNSAFE  /usr/bin/php8.2: PHP 8.2.35, safe from 8.2.36' "$T/summary"
ok grep -qxF 'SUMMARY       3 of 4 PHP binaries are safe, 1 still unsafe' "$T/summary"

apt-cache() {
  cat <<'POLICY'
php8.4-fpm:
  Installed: 8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9
  Candidate: 8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9
  Version table:
 *** 8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9 500
        500 https://packages.sury.org/php noble/main arm64 Packages
        100 /var/lib/dpkg/status
     8.4.26-1+ubuntu24.04.1+deb.sury.org+1 500
        500 https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble/main arm64 Packages
POLICY
}
installed_version() { echo 8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9; }
ok [ "$(package_source php8.4-fpm)" = https://packages.sury.org/php ]
ok [ "$(binary_origin /usr/sbin/php-fpm8.4 php8.4-fpm)" = sury ]
unset -f apt-cache installed_version

installed_version() { echo 8.4.27-1+ubuntu24.04.1+deb.sury.org+1; }
package_candidate() { echo 8.4.27-1+ubuntu24.04.1+deb.sury.org+1; }
binary_owner() { echo php8.4-fpm; }
ondrej_ppa_in_use() { return 0; }
sury_repo_present() { return 1; }
sury_codename() { echo noble/arm64; }
APT_UPDATED=1
UNPATCHED=("/usr/sbin/php-fpm8.4|8.4.27")
sury_index_version() { echo 8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9; }
ok [ "$(binary_action /usr/sbin/php-fpm8.4 VULNERABLE 8.4.27 php8.4-fpm)" = "neither the ondrej/php PPA nor packages.sury.org (noble/arm64) has a fixed php8.4-fpm yet: use --mitigate now and --apply again later" ]
ok not needs_sury_switch
sury_index_version() { echo 8.4.28-2+0~deb.sury.org.1+ubuntu24.04; }
ok [ "$(binary_action /usr/sbin/php-fpm8.4 VULNERABLE 8.4.27 php8.4-fpm)" = "the ondrej/php PPA has no newer php8.4-fpm: switch to packages.sury.org (noble/arm64) and upgrade to 8.4.28-2+0~deb.sury.org.1+ubuntu24.04" ]
ok needs_sury_switch
unset -f installed_version package_candidate binary_owner ondrej_ppa_in_use sury_repo_present sury_codename sury_index_version

exit $FAIL
