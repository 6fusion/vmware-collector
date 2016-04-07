#!/bin/sh
# Start consume.sh script on multiple VMs.
# Assumes VMs setup with test consumption env and comsume.sh is in place
# List of VM IPs should be in psshTestVmIPs.txt

# Validate command line params
if [ "$#" -ne 1 ]; then 
    echo "start_vm_consumption: illegal number of parameters"
    echo "usage: start_vm_consumption.sh <duration (in seconds)>"
    exit
fi

duration=$1
ipFile="./psshTestVmIPs.txt"
errorDir="./logs/psshErr"
outputDir="./logs/psshOut"
sshUser="rgs"

# Clean out any previous log and error files
#rm "$errorDir/192.168.*"
#rm "$outputDir/192.168.*"

# Start pssh
pssh --hosts=$ipFile --outdir=$outputDir --errdir=$errorDir --user=$sshUser --timeout=0 -O StrictHostKeyChecking=no './consume.sh '$duration
