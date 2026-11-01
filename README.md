# Simple restic image for kubernetes

- Meant to be added as sidecar container in kubernetes deployment, statefulset, or daemonset
- Used for backing up kubernetes PVC/PV data to some form of external storage
    - External storage can be:
        - kubernetes PVC backed by NFS or hostPath
        - Supported restic storage (S3, B2, etc) - see restic documentation, https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- Also handles restores itself via `RESTIC_RESTORE=1`  as a initContainer (see below)

## Image contents

Based on `restic/restic` (alpine, multi-arch: amd64/arm64) — restic comes from the base image:

- restic-exporter (Prometheus metrics, see `RESTIC_EXPORTER_VERSION` in Dockerfile)
- InfluxDB v2 CLI (built from the official `influx-cli` module, see `INFLUX_CLI_VERSION` in Dockerfile)
- kubectl, mysql-client, supercronic, tini

## Behavior

On startup the container:

1. Runs `restic unlock`
2. Checks the repository at `RESTIC_REPOSITORY` and initializes it (`restic init`) if it does not exist (restic exit code 10). Any other error (network, credentials, lock) exits non-zero, so a temporarily unreachable repository is never mistaken for a new one
3. Then, depending on configuration:
    - `RESTIC_RESTORE=1`: restores `RESTIC_RESTORE_SNAPSHOT` (default `latest`) into `/`, unless the marker file `${RESTIC_DATA_DIR}/restic-restored.txt` already exists (restore already happened). If the repository is missing, or has no snapshot for `RESTIC_HOST`, the marker is written instead and the container exits (fresh start, nothing to restore). A failed restore exits non-zero without writing the marker, so the initContainer is retried instead of the app starting on partial data
    - `RESTIC_INSTANT_BACKUP=1`: runs a single backup and exits
    - default: starts supercronic with `BACKUP_CRON`/`CHECK_CRON` (job output goes to the container log) and starts the metrics exporter

Additional behavior:

- `RESTIC_BACKUP_ON_EXIT=1` (default): runs a final backup on SIGTERM (pod shutdown)
- Hook scripts: `*.sh` files in `${RESTIC_SCRIPTS_DIR}/{pre,post}-backup.d` and `${RESTIC_SCRIPTS_DIR}/{pre,post}-restore.d` are executed around backup/restore (mount e.g. `configmap`/`emptyDir` at `RESTIC_SCRIPTS_DIR`)
- Marker files (in `${RESTIC_DATA_DIR}${RESTIC_MARKER_FILE_SUBDIR}`):
    - `restic-restored.txt` — written after a successful restore; delete it to force a full restore on next start
    - `restic-restore-inprogress.txt` — written while a restore runs; concurrent backup/restore processes wait for it to disappear

Occasionally check container logs to see backup results.

The image runs as root by default but works as any user (e.g. `securityContext.runAsUser` matching the app's files): cron, the crontab and the restic cache only use `/tmp`.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BACKUP_SOURCE` | `/data` | Folder to be backed up |
| `RESTIC_REPOSITORY` | `/repo` | Restic repository (backup storage location, any restic-supported backend) |
| `RESTIC_PASSWORD` | - | Password for the restic repository (also `RESTIC_PASSWORD_FILE`/`RESTIC_PASSWORD_COMMAND` supported) |
| `BACKUP_CRON` | `00 */24 * * *` | Cron expression for backup timing |
| `CHECK_CRON` | `00 04 * * 1` | Cron expression for `restic check` |
| `RESTIC_FORGET_ARGS` | `--keep-last 7` | Arguments for `restic forget`; set to `""` to never run forget |
| `RESTIC_BACKUP_OPTIONS` | `""` | Extra arguments for `restic backup` |
| `RESTIC_RESTORE_OPTIONS` | `""` | Extra arguments for `restic restore` |
| `RESTIC_HOST` | `localhost` | Host name used for `--host` in backup/restore/snapshots (identifies the source host in the repository). Defaults to the stable name `localhost` so all pods of a workload share one snapshot line — set it explicitly (e.g. per PVC) when multiple sources share a repository |
| `RESTIC_RESTORE` | `0` | `1`: restore on startup (see behavior above) |
| `RESTIC_RESTORE_SNAPSHOT` | `latest` | Snapshot to restore |
| `RESTIC_INSTANT_BACKUP` | `0` | `1`: run a single backup on startup and exit (no cron) |
| `RESTIC_BACKUP_ON_EXIT` | `1` | `1`: run a final backup on SIGTERM |
| `RESTIC_DATA_DIR` | `/data` | Where marker files are stored |
| `RESTIC_MARKER_FILE_SUBDIR` | `/` | Subdirectory for marker files within `RESTIC_DATA_DIR` |
| `RESTIC_SCRIPTS_DIR` | `/restic-scripts` | Directory containing hook script subdirectories |
| `RESTIC_CACHE_DIR` | `/tmp/restic-cache` | restic cache directory (writable for any user) |
| `CRONTAB_FILE` | `/tmp/crontab` | Where the generated crontab is written |
| `REFRESH_INTERVAL` | `600` | Metrics exporter refresh interval in seconds |
| `NICE_ADJUST` | `10` | Nice priority adjustment for backup/check runs |
| `IONICE_CLASS` | `2` | ionice scheduling class (best-effort) |
| `IONICE_PRIO` | `7` | ionice priority (lowest) |
| `LISTEN_PORT` | `8001` | Metrics exporter port |
| `LISTEN_ADDRESS` | `0.0.0.0` | Metrics exporter bind address |

Note: ionice/nice are applied to `restic backup`, `restic forget` and `restic check`.

## Ad-hoc operations (kubectl exec)

The scripts in `/` can be executed directly in a running container for ad-hoc backups, snapshot listings and restores:

```bash
kubectl exec -it <pod> -- ./backup.sh                      # one-off backup (incl. forget + marker file)
kubectl exec -it <pod> -- ./snapshots.sh                   # list snapshots of this host
kubectl exec -it <pod> -- ./restore.sh latest --target /
kubectl exec -it <pod> -- ./restore.sh 062d760a --target / --include 'config/*'
```

- Environment: `kubectl exec` inherits the container environment (`RESTIC_PASSWORD`, `RESTIC_REPOSITORY`, ...). `RESTIC_HOST` falls back to `localhost`, the same host name the cron backups use, so ad-hoc commands stay on the same snapshot line
- `restore.sh` passes all arguments verbatim to `restic restore` (snapshot id, `--target`, `--include`, `--exclude`, ...); without a snapshot id, `restic restore` defaults to the latest snapshot
- Notes:
    - `restore.sh` writes the marker file `restic-restored.txt` — the automatic restore on the next container start is then skipped
    - `restore.sh` sets the `restic-restore-inprogress.txt` marker while running; concurrent backup/restore processes wait for it to disappear
    - restic repository lock: an ad-hoc command running at the same time as a cron backup/check may report `repo already locked` — just retry
    - the scripts assume CWD `/` (they source `./init.inc.sh`), which is the image WORKDIR and the default for `kubectl exec`

## Prometheus metrics

The exporter listens on port `8001` (expose it as a container port and scrape it):

- Global: `restic_snapshots_total`, `restic_size_total`, `restic_uncompressed_size_total`, `restic_blob_count_total`, `restic_compression_ratio`, `restic_check_success`, `restic_locks_total`, ...
- Per snapshot (labels `client_hostname`, `client_username`, `client_version`, ...): `restic_backup_*` (files/dirs/sizes/duration/timestamp)

A ready-made Grafana dashboard ships with upstream: https://github.com/ngosang/restic-exporter/blob/main/grafana/grafana_dashboard.json

Alerts for Failed or Outdated Backups: https://github.com/ngosang/restic-exporter#prometheus--alertmanager-rules

## Usage

### Sidecar (continuous backup)

```yaml
containers:
  - name: app
    image: myapp
    volumeMounts:
      - name: data
        mountPath: /data
  - name: restic
    image: isi006/restic-kubernetes:latest
    env:
      - name: RESTIC_REPOSITORY
        value: s3:my-bucket/backups
      - name: RESTIC_PASSWORD
        valueFrom:
          secretKeyRef:
            name: restic
            key: password
    ports:
      - containerPort: 8001
    volumeMounts:
      - name: data
        mountPath: /data
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

### One-shot restore (initContainer)

```yaml
initContainers:
  - name: restore
    image: isi006/restic-kubernetes:latest
    env:
      - name: RESTIC_RESTORE
        value: "1"
      - name: RESTIC_REPOSITORY
        value: s3:my-bucket/backups
      - name: RESTIC_PASSWORD
        valueFrom:
          secretKeyRef:
            name: restic
            key: password
    volumeMounts:
      - name: data
        mountPath: /data
```

The restore is skipped automatically on subsequent starts (marker file), so the initContainer is a no-op after the first successful restore.

### Instant backup (Job/CronJob)

Set `RESTIC_INSTANT_BACKUP=1` — the container runs one backup and exits with the backup's exit code.

## Building

```bash
./build.sh          # local build (isi006/restic-kubernetes:latest + :$VERSION)
./build_multi.sh    # multi-arch amd64/arm64 via buildx (see comments in script)
./push.sh           # push to registry
```

CI (`.github/workflows/build.yml`) builds and pushes on tags `*.*.*` and on `main`.

## Local testing

```bash
./run.sh            # continuous mode, repo+data in ./testrepo + ./testdata, metrics on :8002
./run_instant.sh    # instant backup mode, with hook scripts from ./testscripts
./run_restore.sh    # restore mode, with hook scripts from ./testscripts
./run_shell.sh      # shell into the image
```

## Kyverno Policies

Injects the sidecar and init Container automatically via a [kyverno](https://kyverno.io) policy (`[% ... %]` are special Jinja2 placeholders):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: [% policy_name %]
spec:
  rules:
    - name: [% policy_name %]
      match:
        resources:
          kinds:
            - Pod
      preconditions:
        - key: "{{ request.object.metadata.annotations.\"restic-backup.isium.de/inject\" || 'disabled' }}"
          operator: Equals
          value: "enabled"
      mutate:
        patchStrategicMerge:
          spec:
            volumes:
              - name: restic-sshkey
                secret:
                  secretName: restic-sshkey
            initContainers:
              - name: restic-restore-init
                command:
                  - /bin/sh
                  - -c
                  - |
                    mkdir -p /root/.ssh
                    cp /root/ssh/* /root/.ssh/
                    chmod 600 /root/.ssh/*
                    /entry.sh
                image: isi006/restic-kubernetes:latest
                securityContext:
                  runAsUser: 0
                  runAsGroup: 0
                envFrom:
                  - secretRef:
                      name: restic-restore-secret
                env:
                  - name: RESTIC_REPOSITORY
                    value: "[% restic_policies_repository %]{{ request.object.metadata.annotations.\"restic-backup.isium.de/backup-name\" }}"
                resources:
                  limits:
                    cpu: 500m
                    memory: 1G
                  requests:
                    cpu: 10m
                    memory: 256M
                volumeMounts:
                  - name: "{{ request.object.metadata.annotations.\"restic-backup.isium.de/data-volume-name\" || 'data' }}"
                    mountPath: /data
                  - name: restic-sshkey
                    mountPath: /root/ssh
                    readOnly: true

            containers:
              - name: restic-backup-sidecar
                image: isi006/restic-kubernetes:latest
                command:
                  - /bin/sh
                  - -c
                  - |
                    mkdir -p /root/.ssh
                    cp /root/ssh/* /root/.ssh/
                    chmod 600 /root/.ssh/*
                    /entry.sh
                securityContext:
                  runAsUser: 0
                  runAsGroup: 0
                ports:
                  - name: restic-metrics
                    containerPort: 8001
                envFrom:
                  - secretRef:
                      name: restic-backup-secret
                env:
                  - name: RESTIC_REPOSITORY
                    value: "[% restic_policies_repository %]{{ request.object.metadata.annotations.\"restic-backup.isium.de/backup-name\" }}"
                resources:
                  limits:
                    cpu: 500m
                    memory: 1G
                  requests:
                    cpu: 10m
                    memory: 256M
                volumeMounts:
                  - name: "{{ request.object.metadata.annotations.\"restic-backup.isium.de/data-volume-name\" || 'data' }}"
                    mountPath: /data
                  - name: restic-sshkey
                    mountPath: /root/ssh
                    readOnly: true
```

This is only an example (with a ssh repo) as a starting point. In this case a Secret for the env vars are also needed:

```yaml

---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: [% policy_name %]
spec:
  rules:
    - name: [% policy_name %]-sshkey
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        generateExisting: true
        synchronize: true
        apiVersion: v1
        kind: Secret
        name: restic-sshkey
        namespace: "{{ request.object.metadata.name }}"

        data:
          data:
            id_ed25519: [% restic_policies_sshkey_private_b64 %]
            config: SG9zdCAqCiAgU3RyaWN0SG9zdEtleUNoZWNraW5nIG5vCiAgVXNlcktub3duSG9zdHNGaWxlIC9kZXYvbnVsbAo=

    - name: [% policy_name %]-restore
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        generateExisting: true
        synchronize: true
        apiVersion: v1
        kind: Secret
        name: restic-restore-secret
        namespace: "{{ request.object.metadata.name }}"

        data:
          stringData:
            RESTIC_PASSWORD: [% restic_policies_password %]
            RESTIC_HOST: localhost
            RESTIC_RESTORE: "1"

    - name: [% policy_name %]-backup
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        generateExisting: true
        synchronize: true
        apiVersion: v1
        kind: Secret
        name: restic-backup-secret
        namespace: "{{ request.object.metadata.name }}"

        data:
          stringData:
            RESTIC_PASSWORD: [% restic_policies_password %]
            RESTIC_HOST: localhost
            REFRESH_INTERVAL: "900"
            BACKUP_CRON: "30 * * * *"
            RESTIC_FORGET_ARGS: "--keep-last 12 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 100 --prune"
```

To create a PodMonitor to monitor your Backups in every namespace use a policy like this:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: [% policy_name %]
spec:
  rules:
    - name: [% policy_name %]
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        generateExisting: true
        synchronize: true
        apiVersion: monitoring.coreos.com/v1
        kind: PodMonitor
        name: restic-pod-monitor
        namespace: "{{ request.object.metadata.name }}"

        data:
          kind: PodMonitor
          metadata:
            name: restic-pod-monitor
          spec:
            podMetricsEndpoints:
              - port: restic-metrics
                path: /
            selector:
              matchLabels:
                restic-backup.isium.de/enabled: "true"
          labels:
            monitoring.coreos.com/name: restic-pod-monitor
            monitoring.coreos.com/k8s-app: kube-system

```