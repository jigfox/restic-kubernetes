#!/bin/sh

. ./init.inc.sh

backup_on_exit() {
  echo "Shutdown... backup on exit"
  ./backup.sh
}

if [ "${RESTIC_BACKUP_ON_EXIT}" = "1" ]; then
  trap backup_on_exit SIGTERM
fi

echo "Starting... image version ${IMAGE_VERSION}"

export RESTIC_HOST=${RESTIC_HOST:-localhost}

echo "unlock at startup"
restic unlock

echo -n "check for existence/sanity of repo, status: "
restic snapshots > /dev/null 2>&1
repo_status=$?

echo $repo_status

# only exit code 10 means the repository does not exist yet; anything else
# (network, credentials, lock) must not be mistaken for a new repository
if [ $repo_status != 0 ] && [ $repo_status != 10 ]; then
  echo "Repository '${RESTIC_REPOSITORY}' is not accessible (status $repo_status)."
  exit 1
fi

if [ $repo_status != 0 ] && [ "${RESTIC_RESTORE}" = "1" ]; then
  echo "Restore is requested but the repository '${RESTIC_REPOSITORY}' does not exists, assuming starting from scratch -> skip restore."
  markRestored
  exit 0
fi

# initialize repo if it doesn't exist
if [ $repo_status != 0 ]; then
  echo "Initializing restic repository at '${RESTIC_REPOSITORY}'..."
  restic init
  init_status=$?

  if [ $init_status != 0 ]; then
    echo "Failed to initialize restic repository."
    exit 1
  fi
fi

if [ "${RESTIC_RESTORE}" = "1" ]; then
  if [ ! -f ${RESTORED_MARKER_FILE} ]; then
    echo "Restore is requested and the file '${RESTORED_MARKER_FILE}' is not present -> going to restore."
    ./restore.sh ${RESTIC_RESTORE_SNAPSHOT} --target /
  else
    echo "Restore is requested and the file '${RESTORED_MARKER_FILE}' is present -> skip restore."
  fi
else
  if [ "${RESTIC_INSTANT_BACKUP}" = "1" ]; then
    echo "Instant backup is requested -> going to backup."
    ./backup.sh
  else
    echo "Continues backup is requested -> configure cron and keep running."

    # supercronic instead of busybox crond: it runs as any user (crond needs
    # root), reads a plain crontab from a writable path, passes the container
    # environment to the jobs and logs their output to stdout. It stays in the
    # background so `wait` can be interrupted by SIGTERM and the backup-on-exit
    # trap still runs.
    {
      echo "${BACKUP_CRON} cd / && ./backup.sh"
      echo "${CHECK_CRON} cd / && ./check.sh"
    } > ${CRONTAB_FILE}
    supercronic -passthrough-logs ${CRONTAB_FILE} &

    echo "Starting metrics exporter..."
    ./exporter.sh &

    echo "Container setup complete."
    wait
  fi
fi
