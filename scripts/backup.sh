#!/bin/sh

set -eu

. ./init.inc.sh

echo "Starting backup at $(date +"%Y-%m-%d %H:%M:%S") (image version ${IMAGE_VERSION}))"
echo "Current dir: $(pwd)"

waitForRestoreCompleted

start=`date +%s`

runScripts pre-backup.d

nice -n ${NICE_ADJUST} ionice -c ${IONICE_CLASS} -n ${IONICE_PRIO} \
    restic backup ${BACKUP_SOURCE} \
    --host ${RESTIC_HOST} \
    --exclude ${RESTORE_IN_PROGRESS_MARKER_FILENAME} \
    ${RESTIC_BACKUP_OPTIONS}

sleep 3

BACKUP_RESULT=$?
if [ $BACKUP_RESULT != 0 ]; then
    echo "Backup failed with status ${BACKUP_RESULT}"
    restic unlock
    exit 1
fi

if [ -n "${RESTIC_FORGET_ARGS}" ]; then
    nice -n ${NICE_ADJUST} ionice -c ${IONICE_CLASS} -n ${IONICE_PRIO} restic forget ${RESTIC_FORGET_ARGS} --host ${RESTIC_HOST}
    FORGET_RESULT=$?
    if [ $FORGET_RESULT != 0 ]; then
        echo "Snapshot pruning failed with status ${FORGET_RESULT}"
        restic unlock
        exit 1
    fi
fi

# a volume that has been backed up counts as restored; only create the
# marker, never rewrite it, so a non-root sidecar needs no write access to a
# marker another user has written
[ -f "${RESTORED_MARKER_FILE}" ] || markRestored

end=`date +%s`
echo "Finished backup at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

runScripts post-backup.d