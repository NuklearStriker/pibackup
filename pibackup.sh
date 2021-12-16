#!/bin/bash

version="v0.1.0"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
LICENSE="MIT License"
COPYRIGHT="Copyright (c) 2021 NuklearStriker"
MYNAME="${SCRIPTNAME%.*}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PISHRINK_OPTS=""

function info() {
	echo "$MYNAME: $1 ..."
}

function error() {
	echo -n "$MYNAME: ERROR occurred in line $1: "
	shift
	echo "$@"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhrspvzZ] server_to_backup

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -a         Compress image in parallel using multiple cores
  -p         Remove logs, apt archives, dhcp leases and ssh hostkeys
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

info "$version $COPYRIGHT $LICENSE"

while getopts ":adhprsvzZ" opt; do
  case "${opt}" in
    a) info "Selected option : [compress_PARALLEL]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -a";;
    d) info "Selected option : [DEBUG]"
	   debug=true
	   PISHRINK_OPTS="$PISHRINK_OPTS -d";;
    h) help;;
    p) info "Selected option : [PREPARE]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -p";;
    r) info "Selected option : [REPAIR]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -r";;
    s) info "Selected option : [DONT_EXPAND]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -s";;
    v) info "Selected option : [VERBOSE]"
	   verbose=true
	   PISHRINK_OPTS="$PISHRINK_OPTS -v";;
    z) info "Selected option : [compress_GZIP]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -z";;
    Z) info "Selected option : [compress_XZ]"
	   PISHRINK_OPTS="$PISHRINK_OPTS -Z";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if (( EUID != 0 )); then
  error $LINENO "You need to be running as root."
  exit 1
else
	SERVER="$1"

	#Usage checks
	if [[ -z "$SERVER" ]]; then
		help
	else
		info "Backing up $SERVER"
	fi
	
	if [ "$debug" = true ]; then
		LOGFILE="${CURRENT_DIR}/log/$SERVER.$TIMESTAMP.log"
		info "Creating log file $LOGFILE"
		#rm "$LOGFILE" &>/dev/null
		exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
		exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
	fi

	ping_dest=$(ping -c4 $SERVER | grep "received" | cut -d ' ' -f 4)
	if [[ "$ping_dest" == "0" ]]; then
		error $LINENO "Server not reachable"
		exit 2
	else
		info "Server is reachable"
	fi
	
	ssh_dest_port=$(nmap $SERVER -PN -p ssh | grep open)
	if [[ -z "$ssh_dest_port" ]]; then
		error $LINENO "SSH port on $SERVER is not open"
		exit 3
	else
		info "SSH port on $SERVER is open"
	fi

	timeout 10s ssh -q $SERVER exit >/dev/null 2>&1
	rc=$?
	if (( $rc != 0 )); then
		case $rc in
			1) err_message="Generic error, usually because invalid command line options or malformed configuration";;
			2) err_message="Connection failed";;
			65) err_message="Host not allowed to connect";;
			66) err_message="General error in ssh protocol";;
			67) err_message="Key exchange failed";;
			68) err_message="Reserved";;
			69) err_message="MAC error";;
			70) err_message="Compression error";;
			71) err_message="Service not available";;
			72) err_message="Protocol version not supported";;
			73) err_message="Host key not verifiable";;
			74) err_message="Connection failed";;
			75) err_message="Disconnected by application";;
			76) err_message="Too many connections";;
			77) err_message="Authentication cancelled by user";;
			78) err_message="No more authentication methods available";;
			79) err_message="Invalid user name";;
			124) err_message="Timeout : SSH_key probably not shared";;
			*) err_message="Error not identified";;
		esac
		error $LINENO "SSH error : $err_message"
		exit 4
	else
		info "SSH connection OK"
	fi
	
	temp_script=$(tempfile -d"${CURRENT_DIR}/tmp" -p"${SERVER}_")
	
	echo "bkp_dir=\$(mktemp -d)" > $temp_script
	echo "mount 192.168.0.90:/export/DATA/Backup \"\$bkp_dir\"" >> $temp_script
	echo "mkdir -p \$bkp_dir/${SERVER}" >> $temp_script
	echo "dd if=/dev/mmcblk0 of=\$bkp_dir/${SERVER}/${TIMESTAMP}.img bs=4M" >> $temp_script
	echo "umount \"\$bkp_dir\"" >> $temp_script
	echo "rmdir \"\$bkp_dir\"" >> $temp_script
	
	info "Starting backup"
	cat $temp_script | ssh $SERVER /bin/bash >/dev/null 2>&1
	rc=$?
	if (( $rc != 0 )); then
		error $LINENO "Backup error."
		exit 5
	else
		info "Backup OK"
		rm $temp_script
	fi
	
	$CURRENT_DIR/pishrink.sh $PISHRINK_OPTS /export/DATA/Backup/$SERVER/$TIMESTAMP.img
	
fi
