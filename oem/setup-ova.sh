#!/bin/bash


while getopts "h:e:" opt; do
    case "$opt" in
        e) METER_ENV=$OPTARG ;;
        h) VM_IP=$OPTARG ;;
    esac
done

if [ "$METER_ENV" = "staging" ]; then
    git checkout staging
    METER_VERSION=beta
elif [ "$METER_ENV" = "production" ]; then
    METER_VERSION=`grep '6fusion/vmware-meter:'   config/production/cloud-config.yml  | head -n1  | tr " " "\n" | grep 6fusion | awk -F: '{print $2}'`
fi

if ([ -z $VM_IP ] || [ -z $METER_ENV ] ); then
    echo "Usage: ./oem/setup-ova.sh -e ENVIRONMENT -h VM_HOST_IP"
    exit 1
fi

MONGO_VERSION=`grep DEPENDENCIES config/$METER_ENV/cloud-config.yml  | tr " " "\n" | grep mongo | awk -F: '{print $2}'`


GRAY='\033[0;90m'
GREEN='\033[1;32m'
BOLD='\033[1;91m'
NC='\033[0m'
SSH="ssh -oStrictHostKeyChecking=no -i oem/core core@$VM_IP"

function log {
    echo -e "${GREEN}$* ${NC}"; }
# pause: log a message and appending trailing ...
#  usage: pause MESSAGE TIME_TO_PAUSE_IN_SECONDS
function pause {
    MESSAGE=$1
    COUNTER=$2
    echo -n -e "${GREEN}$1"
    while [ $COUNTER -gt 1 ]; do
        echo -n .; sleep 1
        let COUNTER=COUNTER-1
    done
    echo -e "${NC}"
}

# scp_cmd: Wraps scp, but also will drop to root in order to write, if necessary
function scp_cmd {
    log "Copying $1 to core@$VM_IP:$2"
    dest=`dirname $2`
    if [ ! -w $dest ]; then
        reset=true
        $SSH sudo chmod o+w $dest
    fi
    scp -q -i oem/core $1 core@$VM_IP:$2
    [ $reset = 'true' ] &&  $SSH sudo chmod o-w $dest; }
# sshq: Run ssh commands without displaying any output
function sshq {
    $SSH -o "PasswordAuthentication no" $* >/dev/null 2>&1;
    rc=$?
    return $rc; }
# sshv: Run ssh commands and show their output
function sshv {
    $SSH -o "PasswordAuthentication no" echo $*
    echo -ne $GRAY
    $SSH -o "PasswordAuthentication no" $*
    rc=$?
    echo -ne $NC
    return $rc
}

# End of functions and variable declartions; beging of actual actions of script

log "Bootstrapping OVA for ${METER_ENV} with meter version: ${METER_VERSION}"

# Generate ssh keys for communicating with VM
if [ ! -f oem/core.pub ]; then
    log "Generating ssh key for setup operations"
    ssh-keygen -f oem/core -N ""
fi

# Test if we can already login without a password
if ! sshq exit; then
    # Script assumes we're on a Mac, so the handy ssh-copy-id command is not natively available
    log "Installing ssh key"
    # Assumes the VM password is 6fusion
    expect <<EOF
spawn $SSH mkdir -p .ssh
expect "password"
send "6fusion\n"
EOF
    expect <<EOF
spawn scp  oem/core.pub core@$VM_IP:.ssh/authorized_keys
expect password: { send 6fusion\r }
expect 100%
sleep 1
EOF
fi

# Get VM into pristine state (i.e., if this script has been run multiple times)
log "Ensuring no cruft remaining from previous runs of this script"
sshq sudo systemctl disable meter-database
sshq sudo systemctl disable meter-registration
sshq sudo systemctl stop meter-registration
sshq sudo systemctl stop meter-database
sshq docker rm meter-database
sshq docker rm meter-registration
sshq docker rm meterDB
sshq sudo rm /usr/share/oem/cloud-config.yml
sshq sudo rm /usr/share/oem/bin/ovfnetworkd.sh
sshq sudo rm -r /var/lib/docker/volumes

# Start adding vmware meter sauce
# Copy up some config and scripts
scp_cmd config/$METER_ENV/cloud-config.yml /usr/share/oem/cloud-config.yml
scp_cmd oem/bin/ovfnetworkd.sh /usr/share/oem/bin/ovfnetworkd.sh
sshv sudo chmod +x /usr/share/oem/bin/ovfnetworkd.sh
if ! sshq docker inspect meterDB; then
    log "Creating meterDB volume for mongo"
    sshv docker run -v /data/db --name meterDB mongo:$MONGO_VERSION /bin/true
fi

# Pull down our container images; Run an instance of mongo and the registration app.
#   This allows us to get the mongo database instance bootstrapped, which greatly improves
#   the initial startup time of the registration wizard for the end user
set -e
log "Starting mongo container"
sshv docker run -d -p 27017:27017 --name meter-database --volumes-from meterDB mongo:$MONGO_VERSION

log "Pulling down 6fusion/vmware-meter:$METER_VERSION"
sshv docker pull 6fusion/vmware-meter:$METER_VERSION

# This key will be removed at the end of this script run; the cloud-config contains a service for generating this uniquely at deploy-time
log "Installing temporary secret key for registration app"
sshv sudo mkdir -p /var/lib/vmware_meter
sshv sudo chown -R core /var/lib/vmware_meter
sshv "head -c 400 /dev/urandom | tr -dc 'a-zA-Z0-9' > /var/lib/vmware_meter/secret_key"
sshv chmod 600 /var/lib/vmware_meter/secret_key
sshv sudo chown root /var/lib/vmware_meter

log "Warming registration web app"
# It takes a bit for mongo to come up for the first time, especially in slow IO environments
# the readable but unescaped version: mongo --eval db.stats()
until sshq docker exec meter-database mongo --eval db.stats\\\(\\\)
do
    pause "\tPausing a moment to let mongo come up" 10
done
# Spin up the registration wizard
sshv docker run -d \
     -p 443:443 -p 80:80 \
     -v /:/host \
     -v /var/run/docker.sock:/var/run/docker.sock \
     -v /var/run/dbus:/var/run/dbus \
     -v /run/systemd:/run/systemd \
     -v /var/lib/vmware_meter:/var/lib/vmware_meter \
     --link meter-database:mongo --name meter-registration \
     6fusion/vmware-meter:$METER_VERSION bundle exec foreman start

# TODO: consider adding this (currently handle by the registration wizard): rake db:mongoid:create_indexes

set +e
until sshq curl localhost
do
    pause "\tWaiting for dashboard to come up" 10
done
pause "\tDashboard up. Waiting a bit to let Rails finish bootstrapping" 10
log "All done; cleaning up"
log "\tStopping mongo and registration containers"
sshq docker stop meter-registration
sshq docker stop meter-database
sshq docker rm meter-database
sshq docker rm meter-registration

log "\tRemoving all traces of setup"
sshq sudo rm /etc/systemd/network/static.network
sshq sudo rm /var/lib/vmware_meter/secret_key
sshq journalctl --vacuum-size=0M
sshq history -c

echo -e "${BOLD}Shutdown virtual machine? [y/n]${NC}"
read answer
if [ $answer = 'y' ]; then
    log "Shutting down CoreOS"
    sshv "HISTFILE= ; rm /home/core/.ssh/authorized_keys && sudo shutdown -h now"
else
    sshv "HISTFILE= ; rm /home/core/.ssh/authorized_keys"
    log "Leaving VM running"
fi

log "Setup completed"

# download page, grep for meter version, slice off all the extra html/json, grep clean output again to ensure match a match against  cruft
curl -s  https://hub.docker.com/r/6fusion/vmware-meter/ | grep $METER_VERSION | head -n1 | grep -q $METER_VERSION || log "There may not be a release note for this version. Please double check this exists on Docker Hub."
