#!/bin/bash

version="v0.1.2"
#Changelog
# v0.1.0 : initial version
# v0.1.1 : variabilize most parameters
# v0.1.2 : add some comments

#Modifiable parameters
BACKUP_SERVER_DIR="/export/DATA/Backup"		#Directory on the backup server where you want to store the backup
BACKUP_SERVER_INTERFACE="br0"				#Interface of the backup server used to do the backup to get the local ip
PISHRINK_DIR="$(pwd)"

#NOT modifiable parameters
CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
LICENSE="MIT License"
COPYRIGHT="Copyright (c) 2021 NuklearStriker"
MYNAME="${SCRIPTNAME%.*}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PISHRINK_OPTS=""
BACKUP_SERVER_IP=$(/sbin/ip -o -4 addr list ${BACKUP_SERVER_INTERFACE} | awk '{print $4}' | cut -d/ -f1)

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

	#Check the name of the server
	if [[ -z "$SERVER" ]]; then
		help
	else
		info "Backing up $SERVER"
	fi
	
	#Generate Debug log file
	if [ "$debug" = true ]; then
		mkdir -p "${CURRENT_DIR}/log"
		LOGFILE="${CURRENT_DIR}/log/$SERVER.$TIMESTAMP.log"
		info "Creating log file $LOGFILE"
		exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
		exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
	fi

	#Check if the Raspberry is pingable
	ping_dest=$(ping -c4 $SERVER | grep "received" | awk '{print $4}')
	if [[ "$ping_dest" == "0" ]]; then
		error $LINENO "Server not reachable"
		exit 2
	else
		info "Server is reachable"
	fi
	
	#Check if SSH port is open on the Raspberry
	ssh_dest_port=$(nmap $SERVER -PN -p ssh | grep open)
	if [[ -z "$ssh_dest_port" ]]; then
		error $LINENO "SSH port on $SERVER is not open"
		exit 3
	else
		info "SSH port on $SERVER is open"
	fi
	
	#Check if we can open a trusted SSH connection with the Raspberry
	timeout 10s ssh -q $SERVER exit >/dev/null 2>&1
	rc=$?
	if (( $rc )); then
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
	
	#Generate the backup script to execute on the Raspberry
	mkdir -p "${CURRENT_DIR}/tmp"
	temp_script=$(tempfile -d"${CURRENT_DIR}/tmp" -p"${SERVER}_")
	
	echo "bkp_dir=\$(mktemp -d)" > $temp_script
	echo "echo \"TempDir for the backup is : \$bkp_dir\"" >> $temp_script
	echo "mount ${BACKUP_SERVER_IP}:${BACKUP_SERVER_DIR} \"\$bkp_dir\"" >> $temp_script
	echo "echo \"${BACKUP_SERVER_IP}:${BACKUP_SERVER_DIR} mounted on \$bkp_dir\"" >> $temp_script
	echo "mkdir -p \$bkp_dir/${SERVER}" >> $temp_script
	echo "echo \"Backup in progress...\"" >> $temp_script
	echo "dd if=/dev/mmcblk0 of=\$bkp_dir/${SERVER}/${TIMESTAMP}.img bs=4M" >> $temp_script
	echo "echo \"Backup completed!\"" >> $temp_script
	echo "echo \"Cleaning...\"" >> $temp_script
	echo "umount \"\$bkp_dir\"" >> $temp_script
	echo "rmdir \"\$bkp_dir\"" >> $temp_script
	
	#Execute the backup script on the Raspberry
	info "Starting backup"
	cat $temp_script | ssh $SERVER /bin/bash
	rc=$?
	if (( $rc != 0 )); then
		error $LINENO "Backup error."
		exit 5
	else
		info "Backup OK"
		rm $temp_script
	fi
	
	#Shrinking of the generated image with the given options
	info "Shrinking"
	$PISHRINK_DIR/pishrink.sh $PISHRINK_OPTS /export/DATA/Backup/$SERVER/$TIMESTAMP.img
	
fi
