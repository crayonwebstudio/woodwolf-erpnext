# Woodwolf ERPNext on Coolify

Production ERPNext ecosystem on the Woodwolf Coolify server, with ERPNext,
Frappe CRM, Frappe HRMS, Frappe Wiki and Frappe Helpdesk on one Frappe site.

Production URL: https://manager.woodwolfdigital.com

Status: live since 2026-11-14 19:58 IST. The site loads with a valid
certificate, the login page shows, all 7 apps are installed, the first
backup is saved and verified, and the Helpdesk desk assets are built.

## Image and versions (actually installed)

The deploy uses a ready-made image, not the Dockerfile build. The image is
**developercrayon/erpnext-custom:v16-helpdesk-compat** (Docker Hub, amd64,
3.5 GB). These are the versions actually installed:

| App | Version |
|---|---|
| Frappe Framework | 16.36.1 |
| ERPNext | 16.37.0 |
| Frappe HRMS | 16.20.1 |
| Frappe Telephony | 0.0.1 (develop) |
| Frappe Helpdesk | 16.1.0 |
| Frappe CRM | 1.86.0 |
| Frappe Wiki | 3.4.0 |

Payments is not in the image and is not installed. ERPNext 16.37.0 does not
declare it as a required app, so the install works without it. The install
loop in `docker-compose.yml` skips any app that is not present in the image
(it checks `sites/apps.txt`), so a future image that adds an app will have
it installed automatically.

The versions originally planned (Frappe 16.55.2, ERPNext 16.55.0, HRMS
16.53.2, CRM 16.0.3, Wiki 3.5.0) are recorded in the `Dockerfile` and
`apps.json` as the build pins, but the live site runs the ready image
versions above. The `Dockerfile` is kept as the build source only; the
deploy does not build from it.

Install order on the site: erpnext, hrms, telephony, helpdesk, crm, wiki
(payments is skipped because it is not in the image). `create-site` in
`docker-compose.yml` is idempotent: it first tests the site with
`bench list-apps`, so on a redeploy it never recreates a healthy site, it
installs only apps that are missing, then runs `bench migrate`.

## Architecture

One prebuilt image is used by every Frappe service, so all services run
identical code. No image build happens on deploy, so a redeploy takes
about 10 to 15 minutes.

Services in `docker-compose.yml`:

- `configurator`: writes the shared site config once (db/redis hosts, ports)
- `create-site`: creates the site on first run, installs the apps present in
  the image, migrates on every deploy. It tests the site first and only
  recreates it when it is missing or unusable.
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

Docker volume names are prefixed with the Coolify application uuid
(`danrl7d9hrvhjgnbfel4urie_`). The compose names are:

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
  when the site is missing or unusable.

## Deploying in Coolify

1. Coolify project: `woodwolf-erpnext`, on the Woodwolf server
   (161.97.132.207). Do not use the Crayonweb server.
2. Application: Docker Compose build pack, public repository
   `crayonwebstudio/woodwolf-erpnext`, branch `main`, compose location
   `/docker-compose.yml`, exposed port `8080`.
3. Set these environment variables on the application:
   - `SITE_NAME=manager.woodwolfdigital.com`
   - `FRAPPE_IMAGE=developercrayon/erpnext-custom:v16-helpdesk-compat`
   - `ADMIN_PASSWORD` (long random, Administrator login)
   - `DB_ROOT_PASSWORD` (long random, MariaDB root)
4. Add the domain in Coolify, under the application Domains page, for the
   `frontend` service: `https://manager.woodwolfdigital.com`. This is
   required. The domain alone in the compose file's Traefik labels is not
   enough, because Coolify never substitutes variables inside Traefik
   labels and the domain was never registered, which left the site serving
   Traefik's default certificate. The compose file also carries a Traefik
   Host rule with the domain hardcoded and the backend port 8080 label.
5. Deploy. No image build runs, the image is pulled (already on the server
   after the first pull). `create-site` creates the site on the first run
   and migrates on every deploy.

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

The `backup` service runs a daily loop (the logic is inline in
`docker-compose.yml`, not `backup.sh`, because the prebuilt image does not
carry `backup.sh`):

- `bench --site <SITE_NAME> backup --with-files` (database + public and
  private files)
- The newest backup set is copied to the separate `woodwolf-erpnext-backups`
  volume under `/backups/YYYY-MM-DD`
- Retention: 7 daily copies, plus a Sunday copy kept for 4 weeks
  (`/backups/weekly-YYYY-MM-DD`)

The backup volume is owned by uid 1000, gid 0 (the frappe user in this
image is uid 1000 with primary group root). The container runs as frappe,
so if the volume is ever recreated it must be chowned to 1000:0 again, or
the backup fails with Permission denied and the container restarts
repeatedly. Note the backup script uses `set -e`, so any failure in a
backup cycle exits the script and Coolify restarts the container.

First backup verified 2026-11-14: `/backups/2026-11-14` holds the database
dump, public files, private files, and site config backup. Integrity
checked 2026-11-14: the database dump passes `gunzip -t`, and both file
archives are valid plain tar.

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

A full restore test to a separate test site has not been run yet. Do not
restore over the live site without a fresh backup first.

## Upgrades

1. Check the release notes for Frappe, ERPNext, HRMS, CRM, Helpdesk and
   Wiki, and confirm the new tags are mutually compatible on the v16 line.
2. Take a backup first (see above) and confirm it is restorable.
3. Obtain or build a new image with the wanted versions, set
   `FRAPPE_IMAGE` in Coolify to the new image tag, and redeploy.
   `create-site` runs `bench migrate` automatically. If the new image
   changes the app list, the install loop installs the apps present in it.
4. Log in and check each workspace (ERPNext, CRM, HRMS, Wiki, Helpdesk).

Never upgrade by editing a live container. Always change the image tag in
Coolify and redeploy, so the deployment is repeatable.

## Maintenance

- Logs: Coolify application logs, or the `woodwolf-erpnext-logs` volume.
- Workers/scheduler health: ERPNext desk, search "Background Jobs" and
  "Scheduled Job Log", or `bench --site <SITE_NAME> doctor`.
- Disk: the Woodwolf host ran out of disk on 2026-11-13 and blocked a
  deploy. If a deploy fails with "No space left on device", run
  `docker system prune -a` on the host (after confirming no needed images
  are only stored there) and redeploy. A build needs about 15 GB free to
  be safe; this deploy does not build, so it needs far less.
- If the Helpdesk desk UI ever 404s again, the built assets are missing.
  Run `bench build --app helpdesk` in the backend container to regenerate
  them into `sites/assets/helpdesk`.
- The older Coolify application named `erpnext` (repo
  `milancrayon/erpnextsetup`, site `erp.woodwolfdigital.com`, status
  degraded/unhealthy) is a separate, earlier attempt. It is not used by
  this deployment and was left untouched.

## Files

- `Dockerfile`: custom image build source (not used by the deploy, which
  uses the prebuilt image)
- `docker-compose.yml`: full production stack
- `apps.json`: pinned app list for the original build plan, for
  reproducibility and future `frappe_docker` builds
- `backup.sh`: reference copy of the daily backup + retention logic. The
  live backup service runs the same logic inline in `docker-compose.yml`,
  because the prebuilt image does not carry `backup.sh`.
- `.env.example`: environment variables, with placeholder values only
