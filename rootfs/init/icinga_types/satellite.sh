

remove_satellite_from_master() {

  echo " [i] remove myself from my master '${ICINGA_MASTER}'"
  # remove myself from master
  #
  code=$(curl \
    --user ${ICINGA_CERT_SERVICE_API_USER}:${ICINGA_CERT_SERVICE_API_PASSWORD} \
    --silent \
    --header 'Accept: application/json'\
    --request DELETE \
    --insecure \
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
    "zone": "${fqdn}",
    "command_endpoint": "${fqdn}",
    "groups": ["icinga-satellites"]
  }
}
EOF
  }

  sleep $(shuf -i 1-10 -n 1)s

  . /init/wait_for/icinga_master.sh

  # add myself as host
  #
  echo " [i] add myself to my master '${ICINGA_MASTER}'"

  code=$(curl \
    --user ${ICINGA_CERT_SERVICE_API_USER}:${ICINGA_CERT_SERVICE_API_PASSWORD} \
    --silent \
    --header 'Accept: application/json' \
    --request PUT \
    --insecure \
    --data "$(api_satellite_host)" \
    https://${ICINGA_MASTER}:5665/v1/objects/hosts/$(hostname -f) )

  echo "${code}"

    if [ $? -eq 0 ]
    then
      :
    else
      status=$(echo "${code}" | jq --raw-output '.results[].code' 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output '.results[].status' 2> /dev/null)

      echo " [E] ${message}"

      add_satellite_to_master
    fi
}


restart_master() {

  sleep $(shuf -i 10-25 -n 1)s

  . /init/wait_for/icinga_master.sh

  # restart the master to activate the zone
  #
  echo " [i] restart the master '${ICINGA_MASTER}' to activate the zone"
  code=$(curl \
    --user ${ICINGA_CERT_SERVICE_API_USER}:${ICINGA_CERT_SERVICE_API_PASSWORD} \
    --silent \
    --header 'Accept: application/json' \
    --request POST \
    --insecure \
    https://${ICINGA_MASTER}:5665/v1/actions/restart-process )

  echo "${code}"

    if [ $? -eq 0 ]
    then
      status=$(echo "${code}" | jq --raw-output '.results[].code' 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output '.results[].status' 2> /dev/null)

      echo " [i] ${message}"
    else
      status=$(echo "${code}" | jq --raw-output '.results[].code' 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output '.results[].status' 2> /dev/null)

      echo " [E] ${message}"

      add_satellite_to_master
    fi

}


create_endpoint_config() {

    echo " [i] configure my endpoint: '${ICINGA_MASTER}'"

    if ( [ $(grep -c "Endpoint \"${ICINGA_MASTER}\"" /etc/icinga2/zones.conf ) -eq 0 ] || [ $(grep -c "host = \"${ICINGA_MASTER}\"" /etc/icinga2/zones.conf) -eq 0 ] )
    then
      cat << EOF > /etc/icinga2/zones.conf

/* the following line specifies that the client connects to the master and not vice versa */
object Endpoint "${ICINGA_MASTER}" { host = "${ICINGA_MASTER}" ; port = "5665" }
object Zone "master" { endpoints = [ "${ICINGA_MASTER}" ] }
/* endpoint for this satellite */
object Endpoint NodeName { host = NodeName }
object Zone ZoneName { endpoints = [ NodeName ] }
/* global zones */
object Zone "global-templates" { global = true }
object Zone "director-global" { global = true }
EOF

      # create an second zone.conf
      # here the endpoint and the own zone configuration are removed.
      # This is created by the master via the API and stored under ${ICINGA_LIB_DIR}.
      # restarting the containers would otherwise cause conflicts
      #
      cat << EOF > ${ICINGA_LIB_DIR}/backup/zones.conf

/* the following line specifies that the client connects to the master and not vice versa */
object Endpoint "${ICINGA_MASTER}" { host = "${ICINGA_MASTER}" ; port = "5665" }
object Zone "master" { endpoints = [ "${ICINGA_MASTER}" ] }
/* endpoint for this satellite */
object Endpoint NodeName { host = NodeName }
object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }
/* global zones */
object Zone "global-templates" { global = true }
object Zone "director-global" { global = true }
EOF
    fi

}


# configure a icinga2 satellite instance
#
configure_icinga2_satellite() {

#   echo " [i] we are an satellite .."
  export ICINGA_SATELLITE=true

  # randomized sleep to avoid timing problems
  #
  sleep $(shuf -i 1-30 -n 1)s

  . /init/wait_for/cert_service.sh
  . /init/wait_for/icinga_master.sh

  # ONLY THE MASTER CREATES NOTIFICATIONS!
  #
  [ -e /etc/icinga2/features-enabled/notification.conf ] && disable_icinga_feature notification

  # all communications between master and satellite needs the API feature
  #
  enable_icinga_feature api

  # remove myself from master
  #
  remove_satellite_from_master

  # we have a certificate
  # validate this against our icinga-master
  #
  if ( [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.key ] && [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.crt ] )
  then
    validate_local_ca
  fi

  [ -f ${ICINGA_LIB_DIR}/backup/zones.conf ] && cp -v ${ICINGA_LIB_DIR}/backup/zones.conf /etc/icinga2/zones.conf

  # we have a certificate
  # restore our own zone configuration
  # otherwise, we can't communication with the master
  #
  if ( [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.key ] && [ -f ${ICINGA_CERT_DIR}/${HOSTNAME}.crt ] )
  then
    :
    create_endpoint_config
    # [ -f ${ICINGA_LIB_DIR}/backup/zones.conf ] && cp -v ${ICINGA_LIB_DIR}/backup/zones.conf /etc/icinga2/zones.conf 2> /dev/null
  else

    # no certificate found
    # use the node wizard to create a valid certificate request
    #
    expect /init/node-wizard.expect 1> /dev/null

    sleep 8s

    # and now we have to ask our master to confirm this certificate
    #
    echo " [i] ask our cert-service to sign our certifiacte"

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
      rm -f /tmp/sign_${HOSTNAME}.json
    else
      status=$(echo "${code}" | jq --raw-output .status 2> /dev/null)
      message=$(echo "${code}" | jq --raw-output .message 2> /dev/null)

      echo " [E] ${message}"

      # TODO
      # wat nu?
    fi

#    if [[ $? -gt 0 ]]
#    then
#      cat /tmp/sign_${HOSTNAME}.json
#      rm -f /tmp/sign_${HOSTNAME}.json
#    fi

    # nice, all fine
    # create our zone config file
    #
    create_endpoint_config


#     echo " [i] configure my endpoint: '${ICINGA_MASTER}'"
#
#     if ( [ $(grep -c "Endpoint \"${ICINGA_MASTER}\"" /etc/icinga2/zones.conf ) -eq 0 ] || [ $(grep -c "host = \"${ICINGA_MASTER}\"" /etc/icinga2/zones.conf) -eq 0 ] )
#     then
#       cat << EOF > /etc/icinga2/zones.conf
#
# /* the following line specifies that the client connects to the master and not vice versa */
# object Endpoint "${ICINGA_MASTER}" { host = "${ICINGA_MASTER}" ; port = "5665" }
# object Zone "master" { endpoints = [ "${ICINGA_MASTER}" ] }
# /* endpoint for this satellite */
# object Endpoint NodeName { host = NodeName }
# object Zone ZoneName { endpoints = [ NodeName ] }
# /* global zones */
# object Zone "global-templates" { global = true }
# object Zone "director-global" { global = true }
# EOF
#
#       # create an second zone.conf
#       # here the endpoint and the own zone configuration are removed.
#       # This is created by the master via the API and stored under ${ICINGA_LIB_DIR}.
#       # restarting the containers would otherwise cause conflicts
#       #
#       cat << EOF > ${ICINGA_LIB_DIR}/backup/zones.conf
#
# /* the following line specifies that the client connects to the master and not vice versa */
# object Endpoint "${ICINGA_MASTER}" { host = "${ICINGA_MASTER}" ; port = "5665" }
# object Zone "master" { endpoints = [ "${ICINGA_MASTER}" ] }
# /* endpoint for this satellite */
# /* object Endpoint NodeName { host = NodeName } */
# object Zone ZoneName { endpoints = [ NodeName ]; parent = "master" }
# /* global zones */
# object Zone "global-templates" { global = true }
# object Zone "director-global" { global = true }
# EOF
#     fi
  fi

  # rename the hosts.conf and service.conf
  # this both comes now from the master
  # yeah ... distributed monitoring rocks!
  #
  for file in hosts.conf services.conf
  do
    [ -f /etc/icinga2/conf.d/${file} ]    && mv /etc/icinga2/conf.d/${file} /etc/icinga2/conf.d/${file}-SAVE
  done

  ( [ -d /etc/icinga2/zones.d/global-templates ] && [ -f /etc/icinga2/master.d/templates_services.conf ] ) && cp /etc/icinga2/master.d/templates_services.conf /etc/icinga2/zones.d/global-templates/
  [ -f /etc/icinga2/satellite.d/services.conf ] && cp /etc/icinga2/satellite.d/services.conf /etc/icinga2/conf.d/
  [ -f /etc/icinga2/satellite.d/commands.conf ] && cp /etc/icinga2/satellite.d/commands.conf /etc/icinga2/conf.d/satellite_commands.conf

  correct_rights

  # test the configuration
  #
  /usr/sbin/icinga2 \
    daemon \
    --validate

  # validation are not successful
  #
  if [ $? -gt 0 ]
  then
    echo " [E] the validation of our configuration was not successful."
    echo " [E] clean up and restart."

    cp -v /etc/icinga2/zones.conf-distributed /etc/icinga2/zones.conf
    rm -rfv ${ICINGA_LIB_DIR}/backup/*

    echo " [E] headshot ..."

#    ps ax

    s6_pid=$(ps ax | grep s6-svscan | grep -v grep | awk '{print $1}')
    icinga_pid=$(ps ax | grep icinga2 | grep -v grep | awk '{print $1}')

    [ -z "${s6_pid}" ] || kill -9 ${s6_pid} > /dev/null 2> /dev/null
    [ -z "${icinga2_pid}" ] || killall icinga2 > /dev/null 2> /dev/null

    kill -9 1

    exit 1
  fi

  restart_master

  add_satellite_to_master

  sleep 8s
}

configure_icinga2_satellite
