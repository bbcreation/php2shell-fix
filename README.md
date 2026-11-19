# php2shell-fix

## php-smuggling-fix.sh (PHP security release of 19 Nov 2026)

### Quick start

Paste on the server (as root or a sudo user). The script first shows every PHP it found (version, safe version, where it comes from: distro, sury, ppa-ondrej, source, hestia, frankenphp) and the plan (which packages it upgrades, what it builds from source, which php-fpm it restarts), then asks `Proceed with the plan above? [y/N]`. Nothing changes until you answer `y`:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | sudo bash -s -- --apply
```

Everything in one go (upgrade, mitigations for what cannot be patched yet, then FrankenPHP unless you answered no):

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | sudo bash -s -- --apply --mitigate; [ $? -ne 3 ] && curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/frankenphp-update.sh | sudo bash -s --
```

### Step by step

1. Report without changes: `--check` (command below). It shows the same table and plan as `--apply`, and the `EXPOSED` and `FPM` lines.
2. Patch: `--apply`, read the plan, answer `y`.
3. Read the `--- result ---` section: one line per PHP binary, `UPGRADED` (from which PHP and package version to which, and from which repository), `ALREADY SAFE` or `STILL UNSAFE` (with the safe version), then `SUMMARY`. The last line is:
   - `status=OK`: done.
   - `status=STALE`: PHP is patched, but some processes still run the old binary (queue workers, Horizon, supervisor, Octane). Restart them (`php artisan horizon:terminate`, `supervisorctl restart all`) and run `--check` again.
   - `status=VULNERABLE`: the repository has no fixed package yet. Run `--mitigate` now and `--apply` again later.
   - `status=MANUAL`: PHP the script cannot rebuild (no `Configure Command`, a binary outside its prefix, PHP 7.3 or older built from source, PHP 7.4/8.0 with OpenSSL 3) or a binary with an unknown version. Run `--mitigate` and move that PHP to the packages.sury.org build or a supported version.
   - `status=ABORTED`: you answered no (or there was no terminal and no `--yes`), nothing was changed.
4. When the report mentions FrankenPHP, run `frankenphp-update.sh` (see the FrankenPHP section).
5. Check the websites, file uploads with a progress bar, and `nginx -t` / `apache2ctl -t`.

Patches Debian/Ubuntu servers against the 19 Nov 2026 PHP security release: CVE-2026-129289 (PHP-FPM request smuggling, critical), CVE-2026-115560 and CVE-2026-126714 (session RCE), the engine use-after-free bugs (CVE-2026-129182, CVE-2026-129481, CVE-2026-129474) and the rest of the 18 CVEs. Fixed in 8.2.36, 8.3.37, 8.4.28, 8.5.13 and 8.6.0. packages.sury.org also ships backports for 5.6-8.1 (e.g. `8.1.34-13`, `7.4.33-36`). Advisories: https://www.php.net/archive/2026.php#2026-11-19-4, https://github.com/php/php-src/security/advisories/GHSA-qc49-hpvq-g2w6

The fixed versions are higher than the php2shell ones, so this script also covers CVE-2026-109618/109619.

It works like `php2shell-fix.sh` (upgrades packages, switches the ondrej/php PPA to packages.sury.org when needed), and additionally:

- shows the plan and asks for confirmation before it changes anything (`--yes` skips the question), and at the end a `--- result ---` section with the version change of every binary. The apt/dpkg output goes to the log, the screen shows only what changed and errors,
- switches the ondrej/php PPA to packages.sury.org only when packages.sury.org has the fixed version for this release and architecture, and does not downgrade extensions there (a package that packages.sury.org has only in an older version, e.g. `php8.4-swoole`, stays from the PPA),
- finds every running php-fpm master (systemd units, Hestia, supervisor programs, masters started by hand) and fully restarts it after the update, so OPcache is emptied and the new binary is loaded: `systemctl restart` for units, `supervisorctl restart` for supervisor programs, `kill -USR2` (php-fpm re-exec) for masters outside both; masters in containers are only reported. After the restart the `FPM` lines show which binary each master runs,
- rebuilds package-less PHP 8.2-8.6 and `hestia-php` from the fixed php.net release, when the binary sits under its configure prefix,
- rebuilds package-less PHP 7.4/8.0/8.1 from the last php.net release (7.4.33, 8.0.30, 8.1.34) plus the security patches from the packages.sury.org source package (`debian/patches`, sha256 checked against the signed-repository index). Debian packaging patches, `NEWS` and the Sury DNS telemetry patches are left out; the build stops if any code hunk does not apply or the CVE-2026-129289 / CVE-2026-109618 fixes are missing. Such binaries keep their version number, so the script records them in `/var/lib/php-smuggling-fix/`,
- upgrades and restarts mod_php (`libapache2-mod-php*`),
- reports the setups the attacks need while PHP is still unpatched (nginx `fastcgi_keep_conn on`, Apache `enablereuse=on`, `session.upload_progress.enabled=On`, `catch_workers_output=yes`),
- with `--mitigate`: sets `fastcgi_keep_conn off` / `enablereuse=off` (after `nginx -t` / `apache2ctl -t`, restored on failure), writes `session.upload_progress.enabled = 0` (and `fatal_error_backtraces = 0` on 8.5) to `/etc/php/<ver>/{fpm,cgi,apache2}/conf.d/99-php-smuggling-mitigation.ini` for unpatched versions only, and removes that file once the version is patched.

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | sudo bash -s -- --check
```

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | sudo bash -s -- --apply
```

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | sudo bash -s -- --apply --mitigate
```

```bash
for h in $(cat servers.txt); do ssh root@$h 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | bash -s -- --check' 2>&1 | grep -E '^(RESULT|EXPOSED)'; done
```

Over ssh without a terminal the script cannot ask, so `--apply` needs `--yes` there (or `ssh -t` to answer on each server):

```bash
for h in $(cat servers.txt); do ssh -t root@$h 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/php-smuggling-fix.sh | bash -s -- --apply'; done
```

| Option | What it does |
|---|---|
| `--check` | report only (default) |
| `--apply` | upgrade PHP packages, rebuild package-less PHP from source, fully restart every php-fpm (and apache2 when mod_php changed) |
| `--mitigate` | turn off FastCGI connection reuse and session upload progress (see above), can be combined with `--apply` |
| `--no-switch-repo` | do not switch from the ondrej/php PPA to packages.sury.org |
| `--no-build-source` | do not build anything from source |
| `--no-restart` | do not restart or reload services |
| `-y`, `--yes` | do not ask for confirmation |

Note: the fixed releases change the default of `session.upload_progress.enabled` to `0`, so upload progress bars stop working unless the application sets it explicitly. Exit code 0 for `OK`/`NOPHP`, 3 for `ABORTED`, 1 otherwise. Log: `/var/log/php-smuggling-fix.log`, backups: `/root/php-smuggling-backup-*`. Tests (need `dpkg` and GNU sed, e.g. `docker run --rm -v "$PWD":/src:ro debian:bookworm bash /src/tests/php-smuggling-fix.test.sh`): `tests/php-smuggling-fix.test.sh`.

`frankenphp-update.sh` now installs FrankenPHP `v1.13.6` (PHP 8.5.13) and treats only the 19 Nov releases as fixed.

## php2shell-fix.sh (CVE-2026-109618, CVE-2026-109619)

Patches Debian/Ubuntu servers (HestiaCP, Laravel Forge) against CVE-2026-109618 and CVE-2026-109619 (php2shell). Official advisory: https://www.php.net/archive/2026.php#2026-10-21-5

It detects every installed PHP version (including inactive ones), upgrades the packages, switches the ondrej/php PPA to packages.sury.org when the PPA has no fix yet, builds package-less PHP 7.4/8.0/8.1 from source (release tag + the fix from php-src), rebuilds the HestiaCP panel PHP (`hestia-php`) from the fixed php.net release when Hestia has not shipped a fixed package yet, and restarts php-fpm.

Always pin a tag or a commit SHA instead of `main`.

## Report (no changes on the server)

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/php2shell-fix.sh | sudo bash -s -- --check
```

## Patch

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/php2shell-fix.sh | sudo bash -s -- --apply
```

## With checksum verification

```bash
curl -fsSLo /tmp/php2shell-fix.sh https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/php2shell-fix.sh && echo "CHECKSUM  /tmp/php2shell-fix.sh" | sha256sum -c && sudo bash /tmp/php2shell-fix.sh --apply
```

Compute the checksum on your own machine: `shasum -a 256 php2shell-fix.sh`.

## Many servers

```bash
for h in $(cat servers.txt); do ssh root@$h 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/php2shell-fix.sh | bash -s -- --check' 2>&1 | grep '^RESULT'; done
```

```bash
cat servers.txt | xargs -P5 -I{} sh -c "ssh root@{} 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/php2shell-fix.sh | bash -s -- --apply' > out-{}.log 2>&1; grep '^RESULT' out-{}.log"
```

## Options

| Option | What it does |
|---|---|
| `--check` | report only (default) |
| `--apply` | upgrade PHP packages, build package-less PHP 7.4/8.0/8.1 from source, rebuild `hestia-php` when needed, restart php-fpm (needs root) |
| `--no-switch-repo` | do not switch from the ondrej/php PPA to packages.sury.org |
| `--no-build-source` | do not build anything from source (package-less PHP 7.4/8.0/8.1 and `hestia-php`) |
| `--no-restart` | do not restart services |

The last output line is `RESULT host=... status=OK|NOPHP|STALE|VULNERABLE|MANUAL`. Exit code 0 for `OK` and `NOPHP`, 1 otherwise.

## FrankenPHP (static binary, e.g. Laravel Octane)

FrankenPHP embeds its own PHP, so system package upgrades do not touch it. `frankenphp-update.sh` installs the FrankenPHP release built with the fixed PHP (default `v1.13.6`): it detects the static or `-gnu` variant, verifies the sha256 digest published by GitHub, refuses to continue if the new binary lacks extensions the old one has (override with `FORCE=1`), keeps a `frankenphp.bak-<php version>` backup, replaces the binary atomically and restarts the matching supervisor program.

Check only (also auto-discovers binaries under `/home`, `/root`, `/srv`, `/opt`, `/var/www`, `/usr/local`):

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/frankenphp-update.sh | sudo bash -s -- --check
```

Update every FrankenPHP binary found, or a specific one:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/frankenphp-update.sh | sudo bash -s --
```

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.5.1/frankenphp-update.sh | sudo bash -s -- /home/forge/example.com
```

## Limitations

- Debian/Ubuntu only (`dpkg` + `apt-get`).
- FrankenPHP bundles its own PHP: `php2shell-fix.sh` only reports it, use `frankenphp-update.sh` to update it.
- Queue workers (Horizon, supervisor) have to be restarted manually: the script lists them as `STALE`.
- Log: `/var/log/php2shell-fix.log`, backups of changed files: `/root/php2shell-backup-*`.
