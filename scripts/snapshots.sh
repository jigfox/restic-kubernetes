#!/bin/sh
export RESTIC_HOST=${RESTIC_HOST:-localhost}

restic snapshots --host ${RESTIC_HOST}
