# ##versions: https://github.com/influxdata/influx-cli/releases
# InfluxDB v2 CLI is not distributed as prebuilt binaries (no GitHub release assets,
# dl.influxdata.com tarballs are gone, apt repo doesn't cover newer Ubuntu releases) -> build from the official CLI module
ARG INFLUX_CLI_VERSION=2.8.0
FROM golang:1.25 AS influx-cli
ARG INFLUX_CLI_VERSION
ENV CGO_ENABLED=0
RUN go install -ldflags "-X main.version=v${INFLUX_CLI_VERSION} -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    github.com/influxdata/influx-cli/v2/cmd/influx@v${INFLUX_CLI_VERSION}

# restic 0.19.x required: restic-exporter 2.x needs total_blob_count in `restic stats --json` ##versions: https://hub.docker.com/r/restic/restic
FROM restic/restic:0.19.1

ARG TARGETARCH=amd64

ARG IMAGE_VERSION=latest

ENV IMAGE_VERSION=${IMAGE_VERSION}
ENV RESTIC_REPOSITORY="/repo"
ENV RESTIC_PASSWORD=""
ENV BACKUP_CRON="00 */24 * * *"
ENV CHECK_CRON="00 04 * * 1"
ENV BACKUP_SOURCE="/data"
ENV RESTIC_FORGET_ARGS="--keep-last 7"
ENV NICE_ADJUST="10"
ENV IONICE_CLASS="2"
ENV IONICE_PRIO="7"
ENV RESTIC_PASSWORD="default_for_tests"
ENV RESTIC_DATA_DIR="/data"
ENV RESTIC_RESTORE="0"
ENV RESTIC_RESTORE_SNAPSHOT="latest"
ENV RESTIC_BACKUP_ON_EXIT="1"
ENV RESTIC_INSTANT_BACKUP="0"
ENV RESTIC_EXPORTER_ENABLED="1"
ENV REFRESH_INTERVAL="600"
ENV RESTIC_SCRIPTS_DIR="/restic-scripts"
ENV RESTIC_MARKER_FILE_SUBDIR="/"
ENV RESTIC_BACKUP_OPTIONS=""
ENV RESTIC_RESTORE_OPTIONS=""
# writable for any user, so the image also runs as non-root
ENV RESTIC_CACHE_DIR="/tmp/restic-cache"
ENV CRONTAB_FILE="/tmp/crontab"

WORKDIR /

# supercronic instead of busybox crond: it runs as any user (crond needs root)
RUN apk add --no-cache py3-pip curl mysql-client mariadb-connector-c tini supercronic

# ##versions: https://github.com/ngosang/restic-exporter/releases
ARG RESTIC_EXPORTER_VERSION=2.1.2
RUN set -e; \
  mkdir /exporter; \
  cd /exporter; \
  # venv without pip (pip is only needed at build time, ~13 MB smaller image)
  python3 -m venv --without-pip ./venv; \
  # dependency pinned in upstream pyproject.toml (v2.x has no requirements.txt) ##versions https://github.com/ngosang/restic-exporter/blob/2.1.2/pyproject.toml
  python3 -m pip --python /exporter/venv/bin/python install --no-cache-dir prometheus-client==0.25.0; \
  wget -q https://raw.githubusercontent.com/ngosang/restic-exporter/${RESTIC_EXPORTER_VERSION}/exporter/exporter.py; \
  # local patch: restic omits total_blob_count/total_file_count from stats JSON when they are 0 (omitempty),
  # exporter crashes with KeyError on empty repositories until first snapshot exists
  sed -i 's/stats_data\["total_blob_count"\]/stats_data.get("total_blob_count", 0)/; s/stats_data\["total_file_count"\]/stats_data.get("total_file_count", 0)/' exporter.py;

# ##versions: https://github.com/kubernetes/kubernetes/releases
ARG KUBECTL_VERSION=1.37.1
RUN set -e; \
    cd /tmp; \
    curl -sLO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    mv kubectl /usr/local/bin/; \
    chmod +x /usr/local/bin/kubectl

COPY --from=influx-cli /go/bin/influx /usr/local/bin/influx

ADD scripts/* /

ENTRYPOINT ["/sbin/tini", "--", "/entry.sh"]
