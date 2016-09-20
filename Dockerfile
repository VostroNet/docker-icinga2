FROM bodsch/docker-alpine-base:1609-01

MAINTAINER Bodo Schulz <bodo@boone-schulz.de>

LABEL version="1.4.0"

ENV TERM xterm

EXPOSE 5665 6666

# ---------------------------------------------------------------------------------------

RUN \
  apk --quiet --no-cache update && \
  apk --quiet --no-cache upgrade && \
  apk --quiet --no-cache add \
    bash \
    pwgen \
    fping \
    unzip \
    netcat-openbsd \
    nmap \
    bc \
    jq \
    yajl-tools \
    ssmtp \
    mailx \
    mysql-client \
    icinga2 \
    openssl \
    monitoring-plugins \
    nrpe-plugin && \
  rm -rf /var/cache/apk/* && \
  cp /etc/icinga2/conf.d.example/* /etc/icinga2/conf.d/ && \
  cp /usr/lib/nagios/plugins/* /usr/lib/monitoring-plugins/ && \
  /usr/sbin/icinga2 feature enable command livestatus compatlog checker mainlog && \
  mkdir -p /run/icinga2/cmd && \
  chmod u+s /bin/busybox

ADD rootfs/ /

VOLUME [ "/etc/icinga2", "/var/lib/icinga2", "/run/icinga2/cmd" ]

CMD [ "/opt/startup.sh" ]

# ---------------------------------------------------------------------------------------
