#!/usr/bin/env bash
# Daily backup for the Woodwolf ERPNext site.
# Runs inside the `backup` service: `bench backup --with-files` writes a
# timestamped database + public/private files backup into
# sites/<site>/private/backups, then this script copies the newest set to
# /backups (a separate persistent volume, outside the sites volume).
# Retention: 7 daily copies, plus a Sunday copy kept for 4 weeks.
set -e
SITE_NAME="${SITE_NAME:?SITE_NAME is not set}"
TODAY="$(date +%F)"
DAY_OF_WEEK="$(date +%u)"

bench --site "$SITE_NAME" backup --with-files

SRC="sites/$SITE_NAME/private/backups"
DEST="/backups/$TODAY"
mkdir -p "$DEST"
# Copy the files this run just created (all naming forms).
find "$SRC" -type f -mmin -10 -exec cp -a {} "$DEST"/ \;

if [ "$DAY_OF_WEEK" = "7" ]; then
  mkdir -p "/backups/weekly-$TODAY"
  cp -a "$DEST"/. "/backups/weekly-$TODAY"/
fi

# Prune daily copies older than 7 days, weekly copies older than 28 days.
find /backups -maxdepth 1 -type d -name "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]" -mtime +7 -exec rm -rf {} + 2>/dev/null || true
find /backups -maxdepth 1 -type d -name "weekly-20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]" -mtime +28 -exec rm -rf {} + 2>/dev/null || true

echo "Backup done for $SITE_NAME on $TODAY, stored in $DEST"
ls -lh "$DEST"
