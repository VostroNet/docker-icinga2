

remove_satellite_from_master() {

  log_info "remove myself from my master '${ICINGA_MASTER}'"

  curl_opts=$(curl_opts)

  # remove myself from master
  #
  code=$(curl \
    ${curl_opts} \
    --request DELETE \
    https://${ICINGA_MASTER}:5665/v1/objects/hosts/$(hostname -f)?cascade=1 )
}

add_satellite_to_master() {

  # helper function to create json for the curl commando below
  #
  api_satellite_host() {
    fqdn="$(hostname -f)"
    ip="$(hostname -i)"
cat << EOF
{
  "templates": [ "satellite-host" ],
  "attrs": {
    "vars.os": "Docker",
    "vars.remote_endpoint": "${fqdn}",
    "vars.satellite": "true",
    "max_check_attempts": "2",
    "check_interval": "30",
    "retry_interval": "10",
    "enable_notifications": true,
    "zone": "${fqdn}",
    "command_endpoint": "${fqdn}",
    "groups": ["icinga-satellites"]
  }
}
EOF
  }

  . /init/wait_for/icinga_master.sh

  curl_opts=$(curl_opts)

  code=$(curl \
    ${curl_opts} \
    --header "Accept: application/json" \
    --request GET \
    https://${ICINGA_MASTER}:5665/v1/objects/hosts/$(hostname -f))

  if [ $? -eq 0 ]
  then
    status=$(echo "${code}" | jq --raw-output '.error' 2> /dev/null)
    message=$(echo "${code}" | jq --raw-output '.status' 2> /dev/null)

    log_info "${status}"
    log_info "${message}"

    # TODO
    # errorhandling, when host already added
    #
    # add myself as host
    #
    log_info "add myself to my master '${ICINGA_MASTER}'"

    code=$(curl \
      ${curl_opts} \
      --header "Accept: application/json" \
      --request PUT \
      --data "$(api_satellite_host)" \
      https://${ICINGA_MASTER}:5665/v1/objects/hosts/$(hostname -f))

    log_info "${code}"

    if [ $? -eq 0 ]
    then
      status=$(echo "${code}" | jq --raw-output '.error' 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output '.status' 2> /dev/null)

      log_info "${message}"

    else
      status=$(echo "${code}" | jq --raw-output '.results[].code' 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output '.results[].status' 2> /dev/null)

      log_error "${message}"

      add_satellite_to_master
    fi


  else
    :

  fi
}


restart_master() {

  sleep $(random)s

  . /init/wait_for/icinga_master.sh

  # restart the master to activate the zone
  #
  log_info "restart the master '${ICINGA_MASTER}' to activate the zone"
  code=$(curl \
    --user ${ICINGA_CERT_SERVICE_API_USER}:${ICINGA_CERT_SERVICE_API_PASSWORD} \
    --silent \
    --header 'Accept: application/json' \
    --request POST \
    --insecure \
    https://${ICINGA_MASTER}:5665/v1/actions/restart-process )

  if [ $? -gt 0 ]
  then
    status=$(echo "${code}" | jq --raw-output '.results[].code' 2> /dev/null)
    message=$(echo "${code}" | jq --raw-output '.results[].status' 2> /dev/null)

    log_error "${code}"
    log_error "${message}"
  fi
}


# NG
endpoint_configuration() {

  log_info "configure our endpoint"

  zones_file="/etc/icinga2/zones.conf"
  backup_zones_file="${ICINGA_LIB_DIR}/backup/zones.conf"

  hostname_f=$(hostname -f)
  api_endpoint="${ICINGA_LIB_DIR}/api/zones/${hostname_f}/_etc/${hostname_f}.conf"
  ca_file="${ICINGA_LIB_DIR}/certs/ca.crt"

  # restore zone backup
  #
  if [ -f ${backup_zones_file} ]
  then
    log_info "restore old zones.conf"
    cp ${backup_zones_file} ${zones_file}
#    sed -i '/^object Endpoint NodeName.*/d' ${zones_file}
#    sed -i 's|^object Zone ZoneName.*}$|object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }|g' ${zones_file}
#    return
  fi

  if [[ $(grep -c "initial zones.conf" ${zones_file} ) -eq 1 ]]
  then
    log_info "first run"
    # first run

    # remove default endpoint and zone configuration for 'NodeName' / 'ZoneName'
    sed -i '/^object Endpoint NodeName.*/d' ${zones_file}
    sed -i '/^object Zone ZoneName.*/d' ${zones_file}

    # add our real icinga master
    cat << EOF >> ${zones_file}
/** added Endpoint for icinga2-master '${ICINGA_MASTER}' - $(date) */
/* the following line specifies that the client connects to the master and not vice versa */
object Endpoint "${ICINGA_MASTER}" { host = "${ICINGA_MASTER}" ; port = "5665" }
object Zone "master" { endpoints = [ "${ICINGA_MASTER}" ] }

/* endpoint for this satellite */
object Endpoint NodeName { host = NodeName }
object Zone ZoneName { endpoints = [ NodeName ] }
EOF
    # remove the initial keyword
    sed -i '/^ \* initial zones.conf/d' ${zones_file}
  fi

  if [[ -e ${api_endpoint} ]]
  then
    log_info "endpoint configuration from our master detected"

    # the API endpoint from our master
    # see into '/etc/icinga2/constants.conf':
    #   const NodeName = "$HOSTNAME"
    #
    # when the ${api_endpoint} file exists, the definition of
    #  'Endpoint NodeName' are double!
    # we remove this definition from the static config file
    log_info "  remove the static endpoint config"
    sed -i '/^object Endpoint NodeName.*/d' ${zones_file}

    # we must also replace the zone configuration
    # with our icinga-master as parent to report checks
    log_info "  replace the static zone config"
    sed -i 's|^object Zone ZoneName.*}$|object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }|g' ${zones_file}
  fi

  if [[ -e ${ca_file} ]]
  then
    log_info "CA from our master replicated"

    # we must also replace the zone configuration
    # with our icinga-master as parent to report checks
    log_info "  replace the static zone config"
    sed -i 's|^object Zone ZoneName.*}$|object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }|g' ${zones_file}
  fi

  # finaly, we create the backup
  log_info "create backup of our zones.conf"
#   cat ${zones_file}
  cp ${zones_file} ${backup_zones_file}
}

# NG
request_certificate_from_master() {

  # we have a certificate
  # restore our own zone configuration
  # otherwise, we can't communication with the master
  #
  if ( [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.key ] && [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.crt ] )
  then
    :
  else

    # no certificate found
    # use the node wizard to create a valid certificate request
    #
    expect /init/node-wizard.expect 1> /dev/null

    sleep 4s

    # and now we have to ask our master to confirm this certificate
    #
    log_info "ask our cert-service to sign our certifiacte"

    . /init/wait_for/cert_service.sh

    code=$(curl \
      --user ${ICINGA_CERT_SERVICE_BA_USER}:${ICINGA_CERT_SERVICE_BA_PASSWORD} \
      --silent \
      --request GET \
      --header "X-API-USER: ${ICINGA_CERT_SERVICE_API_USER}" \
      --header "X-API-PASSWORD: ${ICINGA_CERT_SERVICE_API_PASSWORD}" \
      --write-out "%{http_code}\n" \
      --output /tmp/sign_${HOSTNAME}.json \
      http://${ICINGA_CERT_SERVICE_SERVER}:${ICINGA_CERT_SERVICE_PORT}${ICINGA_CERT_SERVICE_PATH}v2/sign/${HOSTNAME})

    if ( [ $? -eq 0 ] && [ ${code} == 200 ] )
    then

      message=$(jq --raw-output .message /tmp/sign_${HOSTNAME}.json 2> /dev/null)
      rm -f /tmp/sign_${HOSTNAME}.json
      log_info "${message}"
      sleep 5s

      RESTART_NEEDED="true"
    else
      status=$(echo "${code}" | jq --raw-output .status 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output .message 2> /dev/null)

      log_error "${message}"

      # TODO
      # wat nu?
    fi


    endpoint_configuration
  fi
}


# configure a icinga2 satellite instance
#
configure_icinga2_satellite() {

  # TODO check this!
  #
  export ICINGA_SATELLITE=true

  # ONLY THE MASTER CREATES NOTIFICATIONS!
  #
  [ -e /etc/icinga2/features-enabled/notification.conf ] && disable_icinga_feature notification

  # all communications between master and satellite needs the API feature
  #
  enable_icinga_feature api

  # rename the hosts.conf and service.conf
  # this both comes now from the master
  # yeah ... distributed monitoring rocks!
  #
  for file in hosts.conf services.conf
  do
    [ -f /etc/icinga2/conf.d/${file} ] && mv /etc/icinga2/conf.d/${file} /etc/icinga2/conf.d/${file}-SAVE
  done

  # we have a certificate
  # validate this against our icinga-master
  #
  if ( [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.key ] && [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.crt ] ) ; then
    validate_local_ca
    # create the certificate pem for later use
    #
    create_certificate_pem
  fi

  # endpoint configuration are tricky
  #  - stage #1
  #    - we need our icinga-master as endpoint for connects
  #    - we need also our endpoint *AND* zone configuration to create an valid certificate
  #  - stage #2
  #    - after the exchange of certificates, we don't need our endpoint configuration,
  #      this comes now from the master
  #
  endpoint_configuration


  log_info "waiting for our cert-service on '${ICINGA_CERT_SERVICE_SERVER}' to come up"
  . /init/wait_for/cert_service.sh

  log_info "waiting for our icinga master '${ICINGA_MASTER}' to come up"
  . /init/wait_for/icinga_master.sh

  request_certificate_from_master

  ( [ -d /etc/icinga2/zones.d/global-templates ] && [ -f /etc/icinga2/master.d/templates_services.conf ] ) && cp /etc/icinga2/master.d/templates_services.conf /etc/icinga2/zones.d/global-templates/
  [ -f /etc/icinga2/satellite.d/services.conf ] && cp /etc/icinga2/satellite.d/services.conf /etc/icinga2/conf.d/
  [ -f /etc/icinga2/satellite.d/commands.conf ] && cp /etc/icinga2/satellite.d/commands.conf /etc/icinga2/conf.d/satellite_commands.conf

  correct_rights

  # wee need an restart?
  #
  if [ "${RESTART_NEEDED}" = "true" ]
  then
    restart_master

    sed -i 's|^object Zone ZoneName.*}$|object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }|g' /etc/icinga2/zones.conf

    log_warn "waiting for reconnecting and certifiacte signing"

    . /init/wait_for/icinga_master.sh

    # start icinga to retrieve the data from our master
    # the zone watcher will kill this instance, when all datas ready!
    #
    start_icinga
  fi

  # test the configuration
  #
  /usr/sbin/icinga2 \
    daemon \
    --validate

  # validation are not successful
  #
  if [ $? -gt 0 ]
  then
    log_error "the validation of our configuration was not successful."

    exit 1
  fi

  if [[ -e /tmp/add_host ]] && [[ ! -e /tmp/final ]]
  then
    touch /tmp/final

    add_satellite_to_master

    sleep 10s
  fi
}

configure_icinga2_satellite
