# php2shell-fix

Patches Debian/Ubuntu servers (HestiaCP, Laravel Forge) against CVE-2026-109618 and CVE-2026-109619 (php2shell). Official advisory: https://www.php.net/archive/2026.php#2026-10-21-5

It detects every installed PHP version (including inactive ones), upgrades the packages, switches the ondrej/php PPA to packages.sury.org when the PPA has no fix yet, builds package-less PHP 7.4/8.0/8.1 from source (release tag + the fix from php-src) and restarts php-fpm.

Always pin a tag or a commit SHA instead of `main`.

## Report (no changes on the server)

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.1/php2shell-fix.sh | sudo bash -s -- --check
```

## Patch

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.1/php2shell-fix.sh | sudo bash -s -- --apply
```

## With checksum verification

```bash
curl -fsSLo /tmp/php2shell-fix.sh https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.1/php2shell-fix.sh && echo "CHECKSUM  /tmp/php2shell-fix.sh" | sha256sum -c && sudo bash /tmp/php2shell-fix.sh --apply
```

Compute the checksum on your own machine: `shasum -a 256 php2shell-fix.sh`.

## Many servers

```bash
for h in $(cat servers.txt); do ssh root@$h 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.1/php2shell-fix.sh | bash -s -- --check' 2>&1 | grep '^RESULT'; done
```

```bash
cat servers.txt | xargs -P5 -I{} sh -c "ssh root@{} 'curl -fsSL https://raw.githubusercontent.com/bbcreation/php2shell-fix/v1.1/php2shell-fix.sh | bash -s -- --apply' > out-{}.log 2>&1; grep '^RESULT' out-{}.log"
```

## Options

| Option | What it does |
|---|---|
| `--check` | report only (default) |
| `--apply` | upgrade PHP packages, build package-less PHP 7.4/8.0/8.1 from source, restart php-fpm (needs root) |
| `--no-switch-repo` | do not switch from the ondrej/php PPA to packages.sury.org |
| `--no-build-source` | do not build PHP from source |
| `--no-restart` | do not restart services |

The last output line is `RESULT host=... status=OK|NOPHP|STALE|VULNERABLE|MANUAL`. Exit code 0 for `OK` and `NOPHP`, 1 otherwise.

## Limitations

- Debian/Ubuntu only (`dpkg` + `apt-get`).
- FrankenPHP bundles its own PHP: the script only reports the version, fixing it needs a new FrankenPHP release.
- Queue workers (Horizon, supervisor) have to be restarted manually: the script lists them as `STALE`.
- Log: `/var/log/php2shell-fix.log`, backups of changed files: `/root/php2shell-backup-*`.
