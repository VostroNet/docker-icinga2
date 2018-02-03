#

DEMO_DATA=${DEMO_DATA:-'false'}
USER=
GROUP=
ICINGA2_MASTER=${ICINGA2_MASTER:-''}
ICINGA2_HOST=${ICINGA2_HOST:-${ICINGA2_MASTER}}
TICKET_SALT=${TICKET_SALT:-$(pwgen -s 40 1)}

# prepare the system and icinga to run in the docker environment
#
prepare() {

  [[ -d ${ICINGA2_LIB_DIRECTORY}/backup ]] || mkdir -p ${ICINGA2_LIB_DIRECTORY}/backup
  [[ -d ${ICINGA2_CERT_DIRECTORY} ]] || mkdir -p ${ICINGA2_CERT_DIRECTORY}

#   # detect username
#   #
#   for u in nagios icinga
#   do
#     if [[ "$(getent passwd ${u})" ]]
#     then
#       USER="${u}"
#       break
#     fi
#   done
#
#   # detect groupname
#   #
#   for g in nagios icinga
#   do
#     if [[ "$(getent group ${g})" ]]
#     then
#       GROUP="${g}"
#       break
#     fi
#   done

  # read (generated) icinga2.sysconfig and import environment
  # otherwise define variables
  #
  if [[ -f /etc/icinga2/icinga2.sysconfig ]]
  then
    . /etc/icinga2/icinga2.sysconfig

    ICINGA2_RUN_DIRECTORY=${ICINGA2_RUN_DIR}
    ICINGA2_LOG_DIRECTORY=${ICINGA2_LOG}
    USER=${ICINGA2_USER}
    GROUP=${ICINGA2_GROUP}
  else
    ICINGA2_RUN_DIRECTORY=$(/usr/sbin/icinga2 variable get RunDir)
    ICINGA2_LOG_DIRECTORY="/var/log/icinga2/icinga2.log"
    USER=$(/usr/sbin/icinga2 variable get RunAsUser)
    GROUP=$(/usr/sbin/icinga2 variable get RunAsGroup)

  #  ICINGA2_RUNasUSER=$(/usr/sbin/icinga2 variable get RunAsUser)
  #  ICINGA2_RUNasGROUP=$(/usr/sbin/icinga2 variable get RunAsGroup)
  fi

  # change var.os from 'Linux' to 'Docker' to disable ssh-checks
  #
  [[ -f /etc/icinga2/conf.d/hosts.conf ]] && sed -i -e "s|^.*\ vars.os\ \=\ .*|  vars.os = \"Docker\"|g" /etc/icinga2/conf.d/hosts.conf

  [[ -f /etc/icinga2/conf.d/services.conf ]] && mv /etc/icinga2/conf.d/services.conf /etc/icinga2/conf.d/services.conf-distributed
  [[ -f /etc/icinga2/conf.d/services.conf.docker ]] && cp /etc/icinga2/conf.d/services.conf.docker /etc/icinga2/conf.d/services.conf

  # set NodeName (important for the cert feature!)
  #
  sed -i "s|^.*\ NodeName\ \=\ .*|const\ NodeName\ \=\ \"${HOSTNAME}\"|g" /etc/icinga2/constants.conf
  sed -i "s|^.*\ TicketSalt\ \=\ .*|const\ TicketSalt\ \=\ \"${TICKET_SALT}\"|g" /etc/icinga2/constants.conf

  # create global zone directories for distributed monitoring
  #
  if [[ "${ICINGA2_TYPE}" = "Master" ]]
  then
    [[ -d /etc/icinga2/zones.d/global-templates ]] || mkdir -p /etc/icinga2/zones.d/global-templates
    [[ -d /etc/icinga2/zones.d/director-global ]] || mkdir -p /etc/icinga2/zones.d/director-global
  fi

  # create directory for the logfile and change rights
  #
  LOGDIR=$(dirname ${ICINGA2_LOG_DIRECTORY})

  [[ -d ${LOGDIR} ]] || mkdir -p ${LOGDIR}

  chown  ${USER}:${GROUP} ${LOGDIR}
  chmod  ug+wx ${LOGDIR}
  find ${LOGDIR} -type f -exec chmod ug+rw {} \;

  # install demo data
  #
  if [[ "${DEMO_DATA}" = "true" ]]
  then
    cp -fua /init/demo /etc/icinga2/

    sed \
      -i \
      -e \
      's|// include_recursive "demo"|include_recursive "demo"|g' \
      /etc/icinga2/icinga2.conf
  fi
}

# enable Icinga2 Feature
#
enable_icinga_feature() {

  local feature="${1}"

  if [[ $(icinga2 feature list | grep Enabled | grep -c ${feature}) -eq 0 ]]
  then
    log_info "feature ${feature} enabled"
    icinga2 feature enable ${feature} > /dev/null
  fi
}

# disable Icinga2 Feature
#
disable_icinga_feature() {

  local feature="${1}"

  if [[ $(icinga2 feature list | grep Enabled | grep -c ${feature}) -eq 1 ]]
  then
    log_info "feature ${feature} disabled"
    icinga2 feature disable ${feature} > /dev/null
  fi
}

# correct rights of files and directories
#
correct_rights() {

  chmod 1777 /tmp

  if ( [[ -z ${USER} ]] || [[ -z ${GROUP} ]] )
  then
    log_error "no nagios or icinga user/group found!"
  else
    [[ -e /var/lib/icinga2/api/log/current ]] && rm -rf /var/lib/icinga2/api/log/current

    chown -R ${USER}:root     /etc/icinga2
    chown -R ${USER}:${GROUP} /var/lib/icinga2
    chown -R ${USER}:${GROUP} ${ICINGA2_RUN_DIRECTORY}/icinga2
    chown -R ${USER}:${GROUP} ${ICINGA2_CERT_DIRECTORY}
  fi
}

random() {
  echo $(shuf -i 5-30 -n 1)
}

curl_opts() {

  opts=""
  opts="${opts} --user ${CERT_SERVICE_API_USER}:${CERT_SERVICE_API_PASSWORD}"
  opts="${opts} --silent"
  opts="${opts} --insecure"

#  if [ -e ${ICINGA2_CERT_DIRECTORY}/${HOSTNAME}.pem ]
#  then
#    opts="${opts} --capath ${ICINGA2_CERT_DIRECTORY}"
#    opts="${opts} --cert ${ICINGA2_CERT_DIRECTORY}/${HOSTNAME}.pem"
#    opts="${opts} --cacert ${ICINGA2_CERT_DIRECTORY}/ca.crt"
#  fi

  echo ${opts}
}


validate_certservice_environment() {

  CERT_SERVICE_BA_USER=${CERT_SERVICE_BA_USER:-"admin"}
  CERT_SERVICE_BA_PASSWORD=${CERT_SERVICE_BA_PASSWORD:-"admin"}
  CERT_SERVICE_API_USER=${CERT_SERVICE_API_USER:-""}
  CERT_SERVICE_API_PASSWORD=${CERT_SERVICE_API_PASSWORD:-""}
  CERT_SERVICE_SERVER=${CERT_SERVICE_SERVER:-"localhost"}
  CERT_SERVICE_PORT=${CERT_SERVICE_PORT:-"80"}
  CERT_SERVICE_PATH=${CERT_SERVICE_PATH:-"/"}
  USE_CERT_SERVICE=false

  # use the new Cert Service to create and get a valide certificat for distributed icinga services
  #
  if (
    [[ ! -z ${CERT_SERVICE_BA_USER} ]] &&
    [[ ! -z ${CERT_SERVICE_BA_PASSWORD} ]] &&
    [[ ! -z ${CERT_SERVICE_API_USER} ]] &&
    [[ ! -z ${CERT_SERVICE_API_PASSWORD} ]]
  )
  then
    USE_CERT_SERVICE=true

    export CERT_SERVICE_BA_USER
    export CERT_SERVICE_BA_PASSWORD
    export CERT_SERVICE_API_USER
    export CERT_SERVICE_API_PASSWORD
    export CERT_SERVICE_SERVER
    export CERT_SERVICE_PORT
    export CERT_SERVICE_PATH
    export USE_CERT_SERVICE
  fi
}
