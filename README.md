# Woodwolf ERPNext on Coolify

Production ERPNext ecosystem on the Woodwolf Coolify server, with ERPNext,
Frappe CRM, Frappe HRMS, Frappe Wiki and Frappe Helpdesk on one Frappe site.

Production URL: https://manager.woodwolfdigital.com

## Versions (pinned, verified 2026-11-13)

| App | Pin | Notes |
|---|---|---|
| Frappe Framework | v16.55.2 | Inside the `frappe/erpnext:v16.55.0` base image |
| ERPNext | v16.55.0 | Base image `frappe/erpnext:v16.55.0` |
| Frappe HRMS | v16.53.2 | Requires ERPNext on the same site |
| Frappe CRM | v16.0.3 | v16 line. Never use the repo default `develop` branch, it targets the unreleased v17 |
| Frappe Helpdesk | v16.1.0 | v16 line, same warning as CRM |
| Frappe Wiki | v3.5.0 | `version-3` line, the v16-compatible Wiki line. Wiki has no `version-16` branch or v16 tag |
| Frappe Payments | `develop` | No tags, no `version-16` branch. Required by ERPNext payment features |
| Frappe Telephony | `develop` | No tags. Mandatory dependency of Helpdesk, installed before Helpdesk |

All pins were verified live with `git ls-remote` against the official repos
on 2026-11-13. There is no stable v17; `develop` branches target the
unreleased v17 and must not be used for production.

Install order on the site: payments, erpnext, hrms, telephony, helpdesk,
crm, wiki. `create-site` in `docker-compose.yml` enforces this and is
idempotent: on a redeploy it installs only apps that are missing, then runs
`bench migrate`.

## Architecture

One custom image (`Dockerfile`, built from `frappe/erpnext:v16.55.0` with
the apps above baked in) is used by every Frappe service, so all services
run identical code.

Services in `docker-compose.yml`:

- `configurator`: writes the shared site config once (db/redis hosts, ports)
- `create-site`: creates the site on first run, installs all apps in order,
  migrates on every deploy
- `backend`: Frappe gunicorn server (port 8000, internal)
- `frontend`: nginx, serves the site on port 8080, Traefik routing + SSL
- `websocket`: socket.io (port 9000, internal)
- `queue-short` / `queue-long`: background workers
- `scheduler`: Frappe scheduler
- `backup`: daily backup loop, see below
- `db`: MariaDB 11.8
- `redis-cache`: cache (rebuildable, no persistence)
- `redis-queue`: queue, AOF persistence enabled

No database or Redis port is published. Only the frontend is exposed,
through Traefik with automatic Let's Encrypt SSL.

## Persistent volumes

| Volume | Mount | Shared by |
|---|---|---|
| `woodwolf-erpnext-db-data` | `db:/var/lib/mysql` | db |
| `woodwolf-erpnext-sites` | `/home/frappe/frappe-bench/sites` | configurator, create-site, backend, frontend, websocket, queue-short, queue-long, scheduler, backup |
| `woodwolf-erpnext-logs` | `/home/frappe/frappe-bench/logs` | all Frappe services |
| `woodwolf-erpnext-redis-queue-data` | `redis-queue:/data` | redis-queue |
| `woodwolf-erpnext-backups` | `backup:/backups` | backup |

The volume names are unique to this deployment. They do not clash with the
older `erpnext` Coolify application (which used `erpnext-sites` etc.) and
that older application is left untouched.

Safety rules:

- Never run `docker compose down -v` on production.
- Never delete these volumes in Coolify.
- Never create a new site over the existing one; `create-site` only creates
  when `sites/<SITE_NAME>` does not exist.

## Deploying in Coolify

1. Coolify project: `woodwolf-erpnext`, on the Woodwolf server
   (161.97.132.207). Do not use the Crayonweb server.
2. Application: Docker Compose build pack, public repository
   `crayonwebstudio/woodwolf-erpnext`, branch `main`, compose location
   `/docker-compose.yml`, exposed port `8080`.
3. Set these environment variables on the application (runtime + buildtime):
   - `SITE_NAME=manager.woodwolfdigital.com`
   - `FRAPPE_IMAGE=woodwolf-erpnext:v16.55.0`
   - `ADMIN_PASSWORD` (long random, Administrator login)
   - `DB_ROOT_PASSWORD` (long random, MariaDB root)
4. Domain: `manager.woodwolfdigital.com` with HTTPS forced. The domain
   already resolves to the Woodwolf server, so no DNS change is needed.
5. Deploy. The first deploy builds the custom image (allow 20-40 minutes),
   then `create-site` creates the site and installs all seven apps.

### Domain note

The brief named `manager.woodwolffdigital.com`, but that domain does not
exist in public DNS and `woodwolffdigital.com` itself is not registered
(NXDOMAIN, checked 2026-11-13). This deployment uses
`manager.woodwolfdigital.com`, which already resolves to the Woodwolf
server. If `woodwolffdigital.com` is registered later, change `SITE_NAME`
and the Coolify domain to the new name before any production data is
entered, or add it as an extra domain and rename the site with
`bench rename-site`.

## Backups

The `backup` service runs `backup.sh` once a day:

- `bench --site <SITE_NAME> backup --with-files` (database + public and
  private files)
- The newest backup set is copied to the separate `woodwolf-erpnext-backups`
  volume under `/backups/YYYY-MM-DD`
- Retention: 7 daily copies, plus a Sunday copy kept for 4 weeks
  (`/backups/weekly-YYYY-MM-DD`)

Verify a backup any time from inside the `backup` container:

```sh
ls -lh /backups
```

### Restore

1. Stop the Frappe services (backend, workers, scheduler) so nothing writes
   during the restore.
2. Copy the backup files out of `/backups/<date>` (or
   `sites/<site>/private/backups`).
3. Restore the database and files:

```sh
bench --site <SITE_NAME> restore <date>-<site>-database.sql.gz \
  --with-public-files <date>-<site>-files.tar \
  --with-private-files <date>-<site>-private-files.tar
bench --site <SITE_NAME> migrate
```

4. Start the services again and log in to verify.

## Upgrades

1. Check the release notes for Frappe, ERPNext, HRMS, CRM, Helpdesk and
   Wiki, and confirm the new tags are mutually compatible on the v16 line.
2. Take a backup first (see above) and confirm it is restorable.
3. Update the pins in `Dockerfile`, `apps.json` and `FRAPPE_IMAGE`, commit
   and push.
4. Redeploy in Coolify. `create-site` runs `bench migrate` automatically.
5. Log in and check each workspace (ERPNext, CRM, HRMS, Wiki, Helpdesk).

Never upgrade by editing a live container. Always change the pinned
versions in this repo and redeploy, so the build is repeatable.

## Maintenance

- Logs: Coolify application logs, or the `woodwolf-erpnext-logs` volume.
- Workers/scheduler health: ERPNext desk, search "Background Jobs" and
  "Scheduled Job Log", or `bench --site <SITE_NAME> doctor`.
- Disk: the Woodwolf host ran out of disk on 2026-11-13 and blocked a
  deploy. If a deploy fails with "No space left on device", run
  `docker system prune -a` on the host (after confirming no needed images
  are only stored there) and redeploy.
- The older Coolify application named `erpnext` (repo
  `milancrayon/erpnextsetup`, site `erp.woodwolfdigital.com`, status
  degraded/unhealthy) is a separate, earlier attempt. It is not used by
  this deployment and was left untouched.

## Files

- `Dockerfile`: custom image with all apps baked in
- `docker-compose.yml`: full production stack
- `apps.json`: pinned app list, same pins as the Dockerfile, for
  reproducibility and future `frappe_docker` builds
- `backup.sh`: daily backup + retention, run by the `backup` service
- `.env.example`: environment variables, with placeholder values only
