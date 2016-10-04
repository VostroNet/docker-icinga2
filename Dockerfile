
FROM bodsch/docker-alpine-base:1610-01

MAINTAINER Bodo Schulz <bodo@boone-schulz.de>

LABEL version="1.5.1"

ENV TERM xterm

EXPOSE 5665 6666

# ---------------------------------------------------------------------------------------

RUN \
  apk --quiet --no-cache update && \
  apk --quiet --no-cache upgrade && \
  apk --quiet --no-cache add \
    build-base \
    ruby \
    ruby-dev \
    bash \
    nano \
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
   gem install --no-rdoc --no-ri \
     dalli \
     json && \
  cp /etc/icinga2/conf.d.example/* /etc/icinga2/conf.d/ && \
  cp /usr/lib/nagios/plugins/*     /usr/lib/monitoring-plugins/ && \
  /usr/sbin/icinga2 feature enable command livestatus compatlog checker mainlog && \
  mkdir -p /run/icinga2/cmd && \
  chmod u+s /bin/busybox && \
  rm -rf \
    /tmp/* \
    /var/cache/apk/*

COPY rootfs/ /

VOLUME [ "/etc/icinga2", "/var/lib/icinga2", "/run/icinga2/cmd" ]

CMD [ "/opt/startup.sh" ]

# ---------------------------------------------------------------------------------------
