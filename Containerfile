FROM registry.access.redhat.com/ubi10/ubi-minimal

LABEL name="pbs" \
      version="0.1.0" \
      summary="Personal Backup System" \
      description="Containerized backup system using rclone and SQLite" \
      maintainer="crunchtools.com" \
      org.opencontainers.image.source="https://github.com/crunchtools/pbs" \
      org.opencontainers.image.description="Personal Backup System" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

# Install EPEL repo for rclone
COPY etc/epel.repo /etc/yum.repos.d/epel.repo
COPY etc/RPM-GPG-KEY-EPEL-10 /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-10

RUN microdnf install -y --nodocs \
        rclone \
        sqlite \
        file \
        findutils \
        hostname \
        openssh-clients \
        gnupg2 \
        podman-remote \
    && microdnf clean all

COPY pbs.sh /usr/local/bin/pbs.sh
RUN chmod +x /usr/local/bin/pbs.sh

ENTRYPOINT ["/usr/local/bin/pbs.sh"]
CMD ["-B", "-m", "Files HomeDirectories", "-r", "Weekly-1"]
