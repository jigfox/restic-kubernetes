#!/bin/sh

. ./init.inc.sh

start=`date +%s`

echo "Check if restore is already in progress"

waitForRestoreCompletedAndExit

markRestoreInProgress

runScripts pre-restore.d

# a host without any snapshot is a new volume: nothing to restore, start empty.
# A failing listing (network, credentials) is not the same and must not count
# as "no snapshot".
SNAPSHOTS=$(restic snapshots --host ${RESTIC_HOST} --json)
if [ $? != 0 ]; then
  echo "Listing snapshots for host '${RESTIC_HOST}' failed, volume is not marked as restored."
  unmarkRestoreInProgress
  exit 1
fi
if ! echo "${SNAPSHOTS}" | grep -q '"id"'; then
  echo "No snapshot for host '${RESTIC_HOST}' -> nothing to restore, starting empty."
  markRestored
  unmarkRestoreInProgress
  exit 0
fi

echo "Starting restore at $(date +"%Y-%m-%d %H:%M:%S") (image version ${IMAGE_VERSION}))"
restic restore --host ${RESTIC_HOST} ${RESTIC_RESTORE_OPTIONS} ${@}
RESTORE_RESULT=$?

# a failed restore must not be marked as restored, otherwise the app starts on
# partial data and the restore is never retried; exit non-zero instead so the
# init container fails and Kubernetes runs it again
if [ ${RESTORE_RESULT} != 0 ]; then
  echo "Restore failed with status ${RESTORE_RESULT}, volume is not marked as restored."
  unmarkRestoreInProgress
  exit 1
fi

markRestored

unmarkRestoreInProgress

end=`date +%s`
echo "Finished restore at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

runScripts post-restore.d