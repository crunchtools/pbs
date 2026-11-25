FROM registry.access.redhat.com/ubi10/ubi-minimal

LABEL name="pbs" \
      version="3.0.0" \
      summary="Personal Backup System" \
      description="Containerized backup system using rclone and SQLite" \
      maintainer="crunchtools.com" \
      org.opencontainers.image.source="https://github.com/crunchtools/pbs" \
      org.opencontainers.image.description="Personal Backup System" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

RUN microdnf install -y --nodocs \
        sqlite \
        file \
        findutils \
        hostname \
        openssh-clients \
        gnupg2 \
        podman-remote \
        tar \
        gzip \
    && microdnf clean all

# rclone from upstream's release, not EPEL's build: EPEL's 1.75.2 is built with
# go1.26.7 and brotli 1.2.2, fixable Criticals (one KEV) that fail the image
# gate. rclone.lock records the archive and its SHA-256; the build fetches that
# file and installs it only if the checksum matches.
COPY rclone.lock /tmp/rclone.lock
RUN microdnf install -y --nodocs unzip \
    && zip=$(awk '!/^#/ && NF == 2 {print $2}' /tmp/rclone.lock) \
    && ver=${zip#rclone-} && ver=${ver%-linux-amd64.zip} \
    && curl -fsSLo "/tmp/${zip}" "https://downloads.rclone.org/${ver}/${zip}" \
    && (cd /tmp && grep -v '^#' rclone.lock | sha256sum -c -) \
    && unzip -jq "/tmp/${zip}" "${zip%.zip}/rclone" -d /usr/bin \
    && chmod 0755 /usr/bin/rclone \
    && rm -f "/tmp/${zip}" /tmp/rclone.lock \
    && microdnf remove -y unzip \
    && microdnf clean all \
    && rclone version | grep -q "^rclone ${ver}$"

COPY pbs.sh /usr/local/bin/pbs.sh
RUN chmod +x /usr/local/bin/pbs.sh

ENTRYPOINT ["/usr/local/bin/pbs.sh"]
CMD ["-B", "-m", "Files HomeDirectories", "-r", "Weekly-1"]
