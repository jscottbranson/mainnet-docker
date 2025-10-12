#!/bin/bash

# Use param -v to install a specific version (eg. "-v 2023.12.29-release+689"). If omitted, latest version is used.
VERSION="latest"
while getopts "v:" opt; do
  case $opt in
    v) VERSION=$OPTARG ;;
  esac
done

# Do not change below this line unless you know what you're doing :)
# Change the next line to select branch. Acceptable values are "dev" and "release"
RELEASE_TYPE="release"
# Change the next line to update the download URL
URL="https://build.xahau.tech/"

BASE_DIR=/opt/xahaud
USER=xahaud
PROGRAM=xahaud
BIN_DIR=$BASE_DIR/bin
DL_DIR=$BASE_DIR/downloads
DB_DIR=$BASE_DIR/db
ETC_DIR=$BASE_DIR/etc
LOG_DIR=$BASE_DIR/log
SCRIPT_LOG_FILE=$LOG_DIR/update.log
SERVICE_NAME="$PROGRAM.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
CONFIG_FILE="$ETC_DIR/$PROGRAM.cfg"
VALIDATORS_FILE="$ETC_DIR/validators-xahau.txt"

if [ -z "$(find "$BASE_DIR" -mindepth 1 -type f -size +0c -print -quit)" ] && [ -z "$(find "$DIRECTORY" -mindepth 1 -type d -empty -print -quit)" ]; then
  NOBASE=true
else
  NOBASE=false
fi

# For systemd
EXEC_COMMAND="ExecStart=$BIN_DIR/$PROGRAM --silent --conf $ETC_DIR/$PROGRAM.cfg"


# Function to log messages to the log file
log() {
  if [[ "$FIRST_RUN" == true ]]; then
    echo $1
  else
    echo $1  
    echo "$(date +"%Y-%m-%d %H:%M:%S") $1" >> "$SCRIPT_LOG_FILE"
  fi
}


clean() {
  systemctl stop $SERVICE_NAME
  systemctl disable $SERVICE_NAME
  rm $SERVICE_FILE
  systemctl daemon-reload
  userdel $USER
  rm -rf $BASE_DIR
  #rm -rf $LOG_DIR

  
}

#remove next line
#clean
#exit 0

[[ $EUID -ne 0 ]] && echo "This script must be run as root" && exit 1


if ! command -v gpg >/dev/null || ! command -v curl >/dev/null; then
  echo "Error: One or more of the required dependencies (gpg, curl) is not installed. Please install the missing dependencies and try again."
  exit 1
fi

if pgrep -x "xahaud" >/dev/null; then
  xahaud_pid=$(pgrep xahaud)
  xahaud_path=$(readlink -f /proc/$xahaud_pid/exe)
  if [ "$xahaud_path" = "/opt/xahaud/bin/xahaud" ]; then
    echo "xahaud is running in the expected location (/opt/xahaud/bin/xahaud) with PID: $xahaud_pid."
  else
    echo "xahaud is running with PID: $xahaud_pid, but not in the expected location. It is running from: $xahaud_path"
    echo "***Please stop xahaud first.***"
    exit 1
  fi
else
  echo "xahaud is not running. Continuing with installation"

fi



if [ $(id -u $USER > /dev/null 2>&1) ] || [ -f "$BASE_DIR/.firstrun" ]; then
  FIRST_RUN=false  
else  
  FIRST_RUN=true
fi

if ! id "$USER" >/dev/null 2>&1; then
  log "Creating user $USER..."
  useradd --system --no-create-home --shell /bin/false "$USER" &> /dev/null
fi

if [[ "$FIRST_RUN" == true ]]; then
  
  log "Creating directories..."
  log "$PROGRAM base directory is $BASE_DIR"
  if [ ! -d "$BASE_DIR" ]; then
    mkdir "$BASE_DIR"
  fi

  if [ ! -d "$DL_DIR" ]; then
    mkdir "$DL_DIR"
  fi

  if [ ! -d "$BIN_DIR" ]; then
    mkdir "$BIN_DIR"
  fi

  if [ ! -d "$ETC_DIR" ]; then
    mkdir "$ETC_DIR"
  fi

  if [ ! -d "$DB_DIR" ]; then
    mkdir "$DB_DIR"
  fi

  if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
  fi
  
  touch $BASE_DIR/.firstrun
  touch $SCRIPT_LOG_FILE
  chown -R $USER:$USER $BASE_DIR
  cp "$0" /usr/local/bin/.
  echo "This script has been copied to /usr/local/bin and can be invoked without a path."
fi

log "Fetching versions of $PROGRAM..."
filenames=$(curl --silent "${URL}" | grep -Eo '>[^<]+<' | sed -e 's/^>//' -e 's/<$//' | grep -E '^\S+\+[0-9]{2,3}$' | grep -E $RELEASE_TYPE)

if [[ "$VERSION" == "latest" ]]; then
  version_filter="release"
else
  version_filter=$VERSION
fi
version_file=$(curl https://build.xahau.tech/ 2>/dev/null | grep $version_filter | grep -v releaseinfo | sed -E 's/(<a href[^>]*?>).*/\1/g' | sed -E 's/(^[^"]+"|"[^"]+$)//g' | sort -t'B' -k2n -n | tail -n 1)

if [[ "$version_file" == "" ]]; then
  echo "Error: $VERSION could not be found for download"
  exit 1
fi

log "$version_file is available for download"
if [[ -f "$DL_DIR/$version_file" ]]; then
    log "File already downloaded: $version_file"
else
    log "Downloading version file: ${version_file} to $DL_DIR"
    curl --silent --fail "${URL}${version_file}" -o "$DL_DIR/$version_file"
fi

chmod +x "$DL_DIR/$version_file"
chown $USER:$USER "$DL_DIR/$version_file"

# Update symlink if the version file is different from the one it points to
current_file=$(readlink "$BIN_DIR/$PROGRAM")
if [[ "$current_file" != "$DL_DIR/$version_file" ]]; then
    log "Updating symlink: $current_file -> $DL_DIR/$version_file"
    ln -snf "$DL_DIR/$version_file" "$BIN_DIR/$PROGRAM"
    DO_RESTART=true
else
    DO_RESTART=false
fi


if [[ ! -f $SERVICE_FILE ]]; then
  log "Installing service file $SERVICE_FILE..."
# Write service unit file
  cat << EOF > "$SERVICE_FILE"
[Unit]
Description=$PROGRAM Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=+chown -R $USER /opt/xahaud
$EXEC_COMMAND
Restart=on-failure
User=$USER
Group=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME

fi

if [[ ! -f $CONFIG_FILE ]]; then
  log "Creating a default config : $CONFIG_FILE"
  cat << EOF > "$CONFIG_FILE"
# This is the default configuration file for the xahaud daemon.
# Any modifications to this will require a restart of the xahaud daemon

[peers_max]
20

[overlay]
ip_limit = 1024

[network_id]
21337

[server]
port_rpc_admin_local
port_peer
port_ws_admin_local
port_ws_public
port_rpc_public

[port_rpc_admin_local]
port = 5009
ip = 127.0.0.1
admin = 127.0.0.1
protocol = http

[port_peer]
port = 21337
ip = 0.0.0.0
protocol = peer

[port_ws_admin_local]
port = 6009
ip = 127.0.0.1
admin = 127.0.0.1
protocol = ws

[port_ws_public]
port = 6008
ip = 0.0.0.0
protocol = ws
secure_gateway = 127.0.0.1
limit = 50000
send_queue_limit = 20000
websocket_ping_frequency = 10

[port_rpc_public]
port = 6007
ip = 0.0.0.0
protocol = http
secure_gateway = 127.0.0.1

[node_size]
medium

[ledger_history]
256

[relational_db]
backend=rwdb

[node_db]
type=rwdb
online_delete=256
advisory_delete=0

#[node_db]
#type=NuDB
#path=$DB_DIR/nudb
#advisory_delete=0

[database_path]
$DB_DIR

[debug_logfile]
$LOG_DIR/debug.log

[sntp_servers]
time.windows.com
time.apple.com
time.nist.gov
pool.ntp.org

[validators_file]
$VALIDATORS_FILE

[rpc_startup]
{ "command": "log_level", "severity": "warn" }

[ssl_verify]
0

[peer_private]
0

[ips_fixed]
bacab.alloy.ee 21337

# For validators only
[voting]
account_reserve = 1000000
owner_reserve = 200000

# Add validator token stanza etc after this. Don't forget to restart 

# Uncomment for Full History
#[ledger_history]
#full

EOF
fi

if [[ ! -f $VALIDATORS_FILE ]]; then
  log "Creating $VALIDATORS_FILE..."
  cat << EOF > "$VALIDATORS_FILE"
[validator_list_sites]
https://vl.xahau.org

[validator_list_keys]
EDA46E9C39B1389894E690E58914DC1029602870370A0993E5B87C4A24EAF4A8E8

[import_vl_keys]
ED45D1840EE724BE327ABE9146503D5848EFD5F38B6D5FEDE71E80ACCE5E6E738B
ED42AEC58B701EEBB77356FFFEC26F83C1F0407263530F068C7C73D392C7E06FD1
ED2677ABFFD1B33AC6FBC3062B71F1E8397C1505E1C42C64D11AD1B28FF73F4734
EOF
fi
chown -R $USER:$USER $BASE_DIR
if [[ ! -d "/etc/opt/$PROGRAM" ]]; then
  mkdir /etc/opt/xahau
  ln -snf $ETC_DIR/$PROGRAM.cfg /etc/opt/xahau/$PROGRAM.cfg
fi

ln -snf $BIN_DIR/$PROGRAM /usr/local/bin/$PROGRAM

if [[ "$DO_RESTART" == true ]]; then
  log "New version of $PROGRAM installed $version_file."
  log "Please restart by running the following ..."
  log "systemctl stop $PROGRAM.service"
  log "systemctl start $PROGRAM.service"
fi
