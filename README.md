# Atomic Laravel Deploy Script (Multi-PHP, Zero Downtime)

Reliable, idempotent deploy automation for Laravel applications with per-project PHP versions, atomic releases, and rollback support.

Built for production environments where predictability and safety matter.

---

## Features

- Atomic deploy with a `current` symlink
- Automatic rollback when a deploy step fails
- Per-project PHP binary support
- Composer executed with the configured PHP binary
- Deploy lock via `flock` to prevent concurrent runs
- Standard structure (`releases`, `shared`)
- Automatic permission handling for runtime folders
- Post-deploy Artisan health check
- Optional migrations
- Automatic cleanup of old releases
- Frontend support for `npm`, `yarn`, or `pnpm`
- Optional SQLite bootstrap for first deploy (`database.sqlite` creation)

---

## Directory Layout

```text
/var/www/
  └── project/
      ├── current -> releases/20260406_003043
      ├── releases/
      │    ├── 20260406_003043/
      │    ├── 20260405_120240/
      │    └── ...
      └── shared/
           ├── .env
           ├── storage/
           └── bootstrap/cache/
```

---

## Configuration

At the top of `atomicDeploy.sh`:

```bash
declare -A PROJECTS

PROJECTS["project_name"]="repo_url|branch|php_bin|frontend_cmd|composer_mode|run_migrations|artisan_healthcheck"
PROJECTS["atomic_deploy_example_laravel_13"]="git@github.com:DuilioFanton/atomic-deploy-project-example-laravel-13.git|master|/usr/bin/php|build|prod|yes|about"
```

Global variables:

- `BASE_ROOT` (default: `/var/www`)
- `APP_USER` and `WEB_GROUP` (Laravel runtime user/group)
- `DEPLOY_USER` (user for git clone and frontend build; default: current user)
- `KEEP_RELEASES` (number of releases to keep)
- `LOCK_FILE` (default: `/tmp/atomic_deploy.lock`)
- `AUTO_GENERATE_APP_KEY` (`yes` or `no`, default: `no`)

---

## PROJECTS Fields

| Field | Description |
| --- | --- |
| `repo_url` | Git repository URL |
| `branch` | Branch to deploy |
| `php_bin` | Absolute path to PHP binary |
| `frontend_cmd` | Frontend script (example: `build`, `dev`, `none`) |
| `composer_mode` | `prod` or `dev` |
| `run_migrations` | `yes` or `no` |
| `artisan_healthcheck` | Artisan command used as health check |

---

## Usage

```bash
chmod +x atomicDeploy.sh
./atomicDeploy.sh
```

---

## Why Per-Project PHP Matters

The script never relies on mutable global PHP state.

It always executes with the configured binary:

```bash
"$php_bin" artisan ...
"$php_bin" "$(command -v composer)" install ...
```

This avoids hidden platform mismatches and dependency drift between projects.

---

## Security and Safety

- `set -Eeuo pipefail`
- Lock file with `flock`
- Required command validation
- Strict per-project config validation
- PHP binary validation
- Branch validation after clone
- Automatic rollback on error
- `APP_KEY` is fail-fast by default (not auto-generated unless enabled)

---

## Deploy Flow

1. Acquire deploy lock
2. Validate environment and tools
3. Clone repository into a timestamped release
4. Link shared files and directories (`.env`, `storage`, `bootstrap/cache`)
5. Install frontend dependencies/build (when applicable)
6. Install Composer dependencies with the selected PHP binary
7. Ensure app key and SQLite file (when needed)
8. Run migrations (optional)
9. Clear and warm Laravel caches
10. Run health check command
11. Switch `current` symlink atomically
12. Restart queues and cleanup old releases

---

## Rollback Behavior

If any deploy step fails:

- The failed release is removed
- `current` is restored to the previous release (when applicable)
- Existing production traffic remains on the previous healthy release

---

## Health Check

Examples:

```bash
about
route:list
config:cache
```

Executed as:

```bash
php artisan <artisan_healthcheck>
```

If this fails, deploy is aborted and rollback is triggered.

---

## Requirements

- Linux host with Bash
- Git
- Composer
- PHP (multiple versions supported)
- Node.js (optional)
- One of: `npm`, `yarn`, `pnpm` (for frontend projects)
- `sudo` and/or `runuser` when privilege/user switching is needed

---

## Best Practices

- Use SSH keys for Git access
- Keep `.env` in `shared/.env` and never commit it
- Use process supervision for queues
- Enable OPcache in production
- Run deploy first in staging before production

---

## Contributing

Pull requests are welcome.

Potential enhancements:

- Docker-aware workflow
- Native CI/CD integration
- Slack/Discord notifications
- HTTP health checks

---

## License

MIT
