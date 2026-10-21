# php2shell-fix

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

FrankenPHP embeds its own PHP, so system package upgrades do not touch it. `frankenphp-update.sh` installs the FrankenPHP release built with the fixed PHP (default `v1.13.2`): it detects the static or `-gnu` variant, verifies the sha256 digest published by GitHub, refuses to continue if the new binary lacks extensions the old one has (override with `FORCE=1`), keeps a `frankenphp.bak-<php version>` backup, replaces the binary atomically and restarts the matching supervisor program.

Check only (also auto-discovers binaries under `/home`, `/root`, `/srv`, `/opt`, `/var/www`, `/usr/local`):

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/frankenphp-update.sh | sudo bash -s -- --check
```

Update every FrankenPHP binary found, or a specific one:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/frankenphp-update.sh | sudo bash -s --
```

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.4/frankenphp-update.sh | sudo bash -s -- /home/forge/example.com
```

## Limitations

- Debian/Ubuntu only (`dpkg` + `apt-get`).
- FrankenPHP bundles its own PHP: `php2shell-fix.sh` only reports it, use `frankenphp-update.sh` to update it.
- Queue workers (Horizon, supervisor) have to be restarted manually: the script lists them as `STALE`.
- Log: `/var/log/php2shell-fix.log`, backups of changed files: `/root/php2shell-backup-*`.
