#!/usr/bin/env bash
# 
# ----------------------------------- #
# Name:     wlstoolkit.sh
# Author:   ZHANG ZHIJIE
# Email:    norvyn@norvyn.com
# Created:
#   2022/4/29 10:22 -- v1.0
# Modified:
#   2022/5/02 11:01 -- v1.1
#     domain creation test passed, create systemd unit tested
#   2022/5/15 10:08 -- v1.2
#     change wls default start mode from 'dev' to 'prod'
#     add -i option for reading listened ip address from stdin
#     enable boot.properties creation after admin server been started
#     enable boot.properties coping to managed server directories after they are started
#     change '-c -b' form option to action
#     add prompt lines after all systemd unit been created
#   2022/5/16 08:33 -- v1.3
#     add support for '-h' option, which defined home directory of user 'weblogic'
#   2022/7/02 08:24 -- v1.4
#     change '-I' to '-i' in function usage()
# todo separate wls managed server creation from '-c' action
# todo to voiding procedure be broken when admin server not started vis wlst
#
# todo granting permission to user 'weblogic' for running command 'systemctl' without root password authorization.
# todo add method to check if command 'nc' exist
#
# ----------------------------------- #
#
# Procedure
# 1. create domain;
# 2. setup admin server on boot service;
# 3. create managed server[s];
# 4. setup managed server[s] on boot service
#

# read from stdin
DOMAIN_NAME="$DOMAIN_NAME"
MANAGED_SERVERS="$MANAGED_SERVERS"

# operate mode, create or boot
OPERATE_MODE=

# default port of wls console
CONSOLE_PORT=7001
# default ssl port of wls console
CONSOLE_PORT_SSL=7002
# default user of wls console
CONSOLE_USER='weblogic'
# default password of wls console user
CONSOLE_PASSWORD='weblogic@12345'
# default wls console listened ip address
SERVICE_IPADDR='0.0.0.0'
# default home of user 'weblogic'
WEBLOGIC_HOME='/home/weblogic'
# default name of wls Admin Server
ADMIN_SERVER='AdminServer'
DOMAIN_CFG_PATH="$DOMAIN_CFG_PATH"
# whether to allow an existing domain to be overwritten. This option defaults to false.
OVERWRITE='false'
# This value can be dev (development) or prod (production)
# domain start mode 'production' or development, default 'dev'
START_MODE='prod'

export LANG=C
PATH="$PATH:/sbin:/bin:/usr/bin:/usr/sbin:/usr/local/bin"
file_name=$(basename "$0")
used_for="Automatically Create Domain for Weblogic Server"

# shell immediately exit when any command fails unexpected.
# set -e; (false; echo one) | cat; echo two
# result: two
set -e
set -o pipefail

# parameters read from function
# NEVER modify these lines
WLST=
INIT=
WLST_TEMPLATE_PATH=
WLS_VERSION=
WLST_READ_TEMP=
WLST_SELECT_TEMP=
WLST_LOAD_TEMP=
DOMAIN_PATH=
ADMIN_START_SH=
ADMIN_STOP_SH=
ADMIN_SERVICE_NAME='wls_admin.service'
MANAGED_START_SH=
MANAGED_STOP_SH=
SYSTEMCTL_PERMISSION='true'
CONSOLE_URL=
CONSOLE_URL_T3=

# Print usage
usage() 
{
  echo -n "This script is used for: $used_for

USAGE:
  $file_name [ options ] [ action ]

for example:
  $file_name -D domain01 -S server01:8001 -S server02:8002 -c

Options:
  -D DOMAIN         name of domain to be create
  -S SERVER:PORT    name and port of managed server

  -i IP ADDRESS     ip address be listened by weblogic console and provide service, default: 0.0.0.0
  -o [true|false]   whether to allow an existing domain to be overwritten, 'false' by default
  -m [dev | prod]   domain start mode production or development, default: 'prod'
  -p PORT           domain console port, default: '7001'
  -P PORT           domain console ssl port, default: '7002'
  -u                whether to grant command systemctl the executing permission to user 'weblogic', default: 'true'
  -n                name of wls admin server
  -h                home of user 'weblogic', default: '/home/weblogic'

Actions:
  -c                create domain and server, MUST be running as user 'weblogic'

  -b                setup service on boot for admin[managed] server
                    root permission necessary

"
}

function log_error {
  local message=$1

  if [[ $TERM == *"color"* ]]; then
    echo -e "\e[31m$message\e[0m"
  else
    echo $message
  fi
}

function log_info {
  local message=$1

  if [[ $TERM == *"color"* ]]; then
    echo -e "\e[32m$message\e[0m"
  else
    echo "$message"
  fi
}

function log_warn {
  local message=$1

  if [[ $TERM == *"color"* ]]; then
    echo -e "\e[33m${message}\e[0m"
  else
    echo "${message}"
  fi
}

function detect_wlst() {
  if ! WLST=$(find "${WEBLOGIC_HOME}" -name "wlst.sh" -print | grep oracle_common | tail -1); then
    log_error "Weblogic wlst not found, exit with error."
    exit 1
  fi
}

function detect_template() {
  if ! WLST_TEMPLATE_PATH=$(find "${WEBLOGIC_HOME}" -name "wls.jar" -print | grep templates); then
    log_error "Weblogic wlst template not exist"
    exit 1
  fi
}

function detect_init() {
  if ls -l /sbin/init | grep systemd &> /dev/null; then
    INIT="systemd"
    return 0
  fi

  if /sbin/init --version | grep upstart &> /dev/null; then
    INIT="upstart"
    return 0
  fi

  log_error "Unknown INIT detected, exit with error."
  exit 1
}

function detect_wls_version() {
  local version_line=
  if ! version_line=$(find "${WEBLOGIC_HOME}" -name "registry.xml" -exec grep -E "WebLogic Server.*version" {} \; | tail -1); then
    log_error "Read weblogic version from file registry.xml failed."
    exit 1
  fi

  if ! WLS_VERSION=$(echo "$version_line" | grep -oE "[0-9][0-9]"); then
    log_error "Fetch weblogic version failed."
    exit 1
  fi

  return 0
}

function detect_temp_method() {
  case $WLS_VERSION in

  "10")
    WLST_READ_TEMP="readTemplate(${WLST_TEMPLATE_PATH})"
    WLST_SELECT_TEMP=''
    WLST_LOAD_TEMP=''
    ;;

  '12')
    WLST_READ_TEMP=''
    WLST_SELECT_TEMP="selectTemplate('Basic WebLogic Server Domain')"
    WLST_LOAD_TEMP="loadTemplates()"
    ;;

  *)
    log_error "Weblogic WLST template file read method detect failed"
    exit 1
    ;;
  esac

  return 0
}

function check_domain_path() {
  DOMAIN_PATH="${WEBLOGIC_HOME}/user_projects/domains/${DOMAIN_NAME}"

  if ls "$DOMAIN_PATH" >/dev/null 2>&1; then
    log_warn "domain path specified already exist"
  fi

  return 0
}

function check_script_path() {
  ADMIN_START_SH="${DOMAIN_PATH}/startWebLogic.sh"
  ADMIN_STOP_SH="${DOMAIN_PATH}/bin/stopWebLogic.sh"

  MANAGED_START_SH="${DOMAIN_PATH}/bin/startManagedWebLogic.sh"
  MANAGED_STOP_SH="${DOMAIN_PATH}/bin/stopManagedWebLogic.sh"

  if ! ls "$ADMIN_START_SH" >/dev/null 2>&1; then
    log_error "wls script not exist"
    exit 1
  fi

  if ! ls "$ADMIN_STOP_SH" >/dev/null 2>&1; then
    log_error "wls script not exist"
    exit 1
  fi

  if ! ls "$MANAGED_START_SH" >/dev/null 2>&1; then
    log_error "wls script not exist"
    exit 1
  fi

  if ! ls "$MANAGED_STOP_SH" >/dev/null 2>&1; then
    log_error "wls script not exist"
    exit 1
  fi

  return 0

}

function set_wls_env() {
  CONSOLE_URL=http://"$SERVICE_IPADDR":"$CONSOLE_PORT"
  CONSOLE_URL_T3=t3://"$SERVICE_IPADDR":"$CONSOLE_PORT"
  DOMAIN_CFG_PATH="${WEBLOGIC_HOME}/template_cfg"
}

function create_domain() {

  "$WLST" << EOF

# Load the template
# Weblogic Version < 12.2
${WLST_READ_TEMP}

# Weblogic Version >= 12.2
${WLST_SELECT_TEMP}
${WLST_LOAD_TEMP}

# AdminServer settings
cd("/Security/base_domain/User/${CONSOLE_USER}")
set('Password', "${CONSOLE_PASSWORD}")
cd('/Server/AdminServer')
set('Name', "${ADMIN_SERVER}")
set('ListenPort', ${CONSOLE_PORT})
# set('ListenAddress', "${CONSOLE_LISTEN_IPADDR}")
set('ListenAddress', "${SERVICE_IPADDR}")

# todo pause here
# Enable SSL. Attach the keystore later.
create('AdminServer','SSL')
cd('SSL/AdminServer')
set('Enabled', 'True')
set('ListenPort', ${CONSOLE_PORT_SSL})

setOption('OverwriteDomain', "${OVERWRITE}")
setOption('ServerStartMode', "${START_MODE}")
# setOption('AppDir', appConfigPath + '/' + domainName)

writeDomain("${DOMAIN_PATH}")
closeTemplate()

# start admin server
# last parameter 'domainPath' must be specified, because default is 'PWD' where you run the WLST from
startServer("$ADMIN_SERVER", "$DOMAIN_NAME", "$CONSOLE_URL_T3", "$CONSOLE_USER", "$CONSOLE_PASSWORD", "$DOMAIN_PATH")

exit()

EOF

  add_boot_properties "${ADMIN_SERVER}"

  return $?
}

# no necessary if Admin Server created via WLST.
function add_boot_properties() {
  local server_name="$1"
  local security_dir="${DOMAIN_PATH}/servers/${server_name}/security"
  local security_file="${security_dir}/boot.properties"

  if ! ls "$security_dir" >/dev/null 2>&1; then
    log_warn "${security_dir} not exist"
    log_warn "create ${security_dir}"

    if ! mkdir -p "${security_dir}"; then
      log_error "create ${security_dir} failed."
      log_info "if automatically start ${server_name} is necessary"
      log_info "manually setup wls boot.properties file"

      # return 1  # non-critical error, no longer return error code.
    fi
  fi

  if ls "${security_file}" >/dev/null 2>&1; then
    log_warn "${server_name} boot properties file already exist."
    return 0
  fi

  set +e  # without +e option, script failed and exit here.
  local user_and_password=

  read -r -d '' user_and_password <<EOF
username=$CONSOLE_USER
password=$CONSOLE_PASSWORD
EOF

  set -e
  log_info "write boot properties file"
  if ! echo "${user_and_password}" > "${security_file}"; then
    log_error "write boot properties file failed"
    log_info "setup boot.properties manually"
    # return 1  # non-critical error, no longer return error code.
  fi

  return 0
}

function copy_boot_properties() {
  local server_name="$1"

  local source_dir="${DOMAIN_PATH}/servers/${ADMIN_SERVER}/security"
  local target_dir="${DOMAIN_PATH}/servers/${server_name}/"

  log_info "copy boot properties file from admin server to ${server_name}"
  if ! cp -av "$source_dir" "$target_dir"; then  # change -r to -av, void permission been changed to root:root
    log_error "copy boot properties file failed"
    return 1
  fi

  return 0
}

# wls admin server started via WLST, start script not recommanded here.
# by the way, command line ends with '&', cause script never stop naturally.
function start_admin() {
  nohup "${ADMIN_START_SH}" &
}

function stop_admin() {
  return 0
}

function start_server() {
  local server_name="$1"
  "${MANAGED_START_SH}" "$server_name" "${CONSOLE_URL}" &
  return $?
}

function stop_server() {
  local server_name="$1"
  "${MANAGED_STOP_SH}" "$server_name" "${CONSOLE_URL_T3}" "${CONSOLE_USER}" "${CONSOLE_PASSWORD}" &
  return $?
}

function create_managed_servers() {
  log_info "${MANAGED_SERVERS}"
  if [ ! -n "${MANAGED_SERVERS}" ]; then
    log_warn "no managed server name specified"
    return 1
  fi

  for name_and_port in ${MANAGED_SERVERS}; do
    local split=(${name_and_port//:/ })
    local server_name="${split[0]}"
    local server_port="${split[1]}"

    server_port=$(($server_port/1))

    log_info "create managed server $server_name with port $server_port"

    "${WLST}" << EOF

connect("$CONSOLE_USER", "$CONSOLE_PASSWORD", "$CONSOLE_URL_T3")

edit()
startEdit()

# Create the managed Server
cd('/')
cmo.createServer("$server_name")
cd("/Servers/${server_name}")
cmo.setListenAddress("$MANAGED_SERVERS_LISTEN_IPADDR")
cmo.setListenPort($server_port)

save()
activate()

# domainRuntime()
# start("$server_name", 'Server', "$CONSOLE_URL_T3")
# start("$server_name", 'Server', "$MANAGED_SERVERS_LISTEN_IPADDR", $server_port)

disconnect()
exit()

EOF

    # add_boot_properties "${server_name}"
    # todo start managed server via WLST always failed.
  done

  return $?
}

# todo add JAVA memery arguments when start a admin server
function config_admin_onboot() {
  set +e
  local admin_service_unit
  read -r -d '' admin_service_unit << EOF
[Unit]
Description=Weblogic Admin Server Daemon
DefaultDependencies=no
After=sysinit.target local-fs.target network.target

[Service]
User=weblogic
Group=weblogic
Type=simple
ExecStart=$ADMIN_START_SH
# ExecStop=$ADMIN_STOP_SH
ExecStop=/bin/kill -HUP \$MAINPID
# KillMode=control-group
KillMode=mixed
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  set -e
  case $INIT in

  'systemd')
    if ! echo "$admin_service_unit" > /etc/systemd/system/"$ADMIN_SERVICE_NAME"; then
      log_error "Setup wls admin server service on boot failed."
      return 1
    fi

    if ! systemctl daemon-reload; then
      log_error "Reload systemctl daemon failed."
      return 1
    fi

    if ! systemctl enable ${ADMIN_SERVICE_NAME}; then
      log_error "enable admin server service on boot failed"
    fi

#    if ! systemctl start ${ADMIN_SERVICE_NAME}; then
#      log_error "Start WLS Admin Server failed."
#      return 1
#    fi
    waiting_admin_running

    ;;

  'upstart')
    log_warn "Deprecated OS version, only RHEL7 or newer is supported."
    return 1
    ;;

  *)
    log_error "Unsupported platform, exit with error."
    return 1
    ;;

  esac

  return 0
}

function waiting_admin_running() {
  local count=0

  while true; do
    if nc -v -z -w1 "${SERVICE_IPADDR}" "${CONSOLE_PORT}" >/dev/null 2>&1; then
      log_info "wls admin server started"
      return 0
    fi

    log_warn "wls admin server not started yet, trying to restart the service and then waiting for 15s."
    systemctl restart "$ADMIN_SERVICE_NAME"
    sleep 30
    count=$((count+1))
    if [[ "$count" -gt 10 ]]; then
      log_error "wls admin server not started, exit with error."
      return 1
    fi
  done
}

function config_managed_onboot() {
  if [ ! -n "${MANAGED_SERVERS}" ]; then
    log_warn "no managed server name specified"
    return 1
  fi

  for name_and_port in ${MANAGED_SERVERS}; do
    local split=(${name_and_port//:/ })
    local server_name="${split[0]}"
    local server_port="${split[1]}"

    log_info ""
    log_info "create managed server $server_name onboot service"

    set +e
    local managed_service_unit
    read -r -d '' managed_service_unit << EOF
[Unit]
Description=Weblogic Managed Server Daemon
DefaultDependencies=no
After=sysinit.target local-fs.target network.target ${ADMIN_SERVICE_NAME}

[Service]
User=weblogic
Group=weblogic
Type=simple
ExecStart=$MANAGED_START_SH $server_name $CONSOLE_URL_T3
# ExecStop=$MANAGED_STOP_SH $server_name $CONSOLE_URL_T3
ExecStop=/bin/kill -HUP \$MAINPID
# KillMode=control-group
KillMode=mixed
Restart=no
# Restart=on-failure
# RestartSec=60s

[Install]
WantedBy=multi-user.target
EOF
# systemd unit ExecStop with kill command is more effective than wls stop script
    service_name="wls_${server_name}"
    set -e
    case $INIT in
    'systemd')

      if ! echo "$managed_service_unit" > /etc/systemd/system/"$service_name".service; then
        log_error "Setup Weblogic Managed Server $server_name Service on boot failed."
        return 1
      fi

      systemctl daemon-reload

      log_warn "manually start $server_name with following command line as system user 'weblogic'"
      log_info "WLS ADMIN USERNAME: $CONSOLE_USER"
      log_info "WLS ADMIN PASSWORD: $CONSOLE_PASSWORD"

      log_info "$MANAGED_START_SH $server_name $CONSOLE_URL_T3"
      # log_info "$MANAGED_STOP_SH $server_name $CONSOLE_URL_T3 $CONSOLE_USER $CONSOLE_PASSWORD"
      log_warn "AFTER managed server started, press ENTER to be continued."
      read

      copy_boot_properties "$server_name"
      # add_boot_properties "$server_name"

      log_info "enable $server_name service on boot"
      if ! systemctl enable "$service_name"; then
        log_error "${server_name} service on boot failed"
      fi

      if nc -v -z -w1 "${SERVICE_IPADDR}" "${server_port}" >/dev/null 2>&1; then
        log_info "wls server $server_name already started"
        continue

      else
        log_info "start $server_name service via systemctl"
        waiting_admin_running
        if ! systemctl start "$service_name"; then
          log_error "${server_name} service start failed"
        fi
      fi

      ;;

    'upstart')
      log_warn "Deprecated OS version, only RHEL7 or newer is supported."
      return 1
      ;;

    *)
      log_error "Unsupported platform, exit with error."
      return 1
      ;;

    esac
  done

  return 0
}

# main script
if [ "$#" -eq 0 -o "$1" = '-h' -o "$1" = '--help' ]; then
  usage >&2
  exit 1
fi

while getopts "cbD:S:o:m:p:u:n:i:h:P:" opt; do
  case "$opt" in

  'c')
    OPERATE_MODE='create'
    ;;
  'b')
    OPERATE_MODE='onboot'
    ;;
  'D')
    DOMAIN_NAME="$OPTARG"
    ;;
  'S')
    MANAGED_SERVERS+="$OPTARG "
    ;;
  'o')
    answer="$OPTARG"
    if [[ "$answer" =~ ^([Tt]ure)$ ]]; then
      OVERWRITE='true'
    fi
    ;;
  'm')
    mode="$OPTARG"
    if [ "$mode" = 'prod' ]; then
      START_MODE='proc'
    fi
    ;;
  'p')
    CONSOLE_PORT="$OPTARG"
    ;;
  'P')
    CONSOLE_PORT_SSL="$OPTARG"
    ;;
  'u')
    SYSTEMCTL_PERMISSION="$OPTARG"
    ;;
  'n')
    ADMIN_SERVER="$OPTARG"
    ;;
  'i')
    SERVICE_IPADDR="$OPTARG"
    ;;
  'h')
    WEBLOGIC_HOME="$OPTARG"
    ;;
  *)
    log_warn "option not supported."
    ;;
  esac

done

check_domain_path
detect_init
set_wls_env

case "$OPERATE_MODE" in
  'create')

    user=$(whoami)

    log_info "create domain option detected, domain name ${DOMAIN_NAME}, current user ${user}"

    if [ "$user" != 'weblogic' ]; then
      log_warn "user 'weblogic' is necessary, exit with error."
      exit 1
    fi

    if ! detect_wlst; then
      exit 1
    fi

    if ! detect_template; then
      exit 1
    fi

    if ! detect_wls_version; then
      exit 1
    fi

    if ! detect_temp_method; then
      exit 1
    fi

    if ! create_domain; then
      log_error "create domain failed, find more detail from WLST output"
      exit 1
    fi

    # start_admin
    # add boot file not necessary
    # create domain via WLST and set usr/password, boot.properties file already exist.
    create_managed_servers

    log_info "create wls admin & managed server done"
    log_warn "user: $CONSOLE_USER"
    log_warn "pass: $CONSOLE_PASSWORD"
    ;;

  'onboot')

    if ! check_script_path; then
      log_error "check wls script path failed"
    fi

    config_admin_onboot

    config_managed_onboot

    log_info "for allowing user 'weblogic' to manage the wls services"
    log_info "run the following command, add the line to the end of the file"
    log_info "visudo"
    log_info "weblogic localhost=/sbin/systemctl"

    if [[ "$SYSTEMCTL_PERMISSION" =~ ^([Tt]rue)$ ]]; then
      log_info "systemctl permission granted, add config to file '/etc/sudoers'"

      if grep 'weblogic' /etc/sudoers >/dev/null 2>&1; then
        log_warn "user 'weblogic' has already granted sudo permission"

      else
        if ! echo "weblogic localhost=/sbin/systemctl" >> /etc/sudoers; then
          log_error "grant permission failed"
          exit 1
        fi

      fi
    fi

    log_info "wls on boot service setup done"
    log_info "wls servers be managed with following files via systemctl command:"
    ls -1 /etc/systemd/system/wls*
    ;;

  *)
    log_error "Unknown option, exit with error"
    exit 1
    ;;

esac

exit 0
