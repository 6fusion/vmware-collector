#!/bin/bash 
#
# Virual machine shell script to consume computer resources in a repeatable/predictable manner
# 4/6/2015 - Bob Steinbeiser

echo "VM comsumption generator script"

# Validate command line params
if [ "$#" -ne 1 ]; then 
    echo "consumption: illegal number of parameters"
    echo "usage: consumption <duration (in seconds)>"
    exit
fi

duration=$1
srcFile="small.file"

# Create a unique destination filename based on ip address
id=`hostname -I | sed 's/^.*\.\([^.]*\)$/\1/' | xargs`
destFile=$id"-"$srcFile

start=$(date +"%x %r %Z")
echo "Started at: $start"

# Consume: CPU(usage, usage in MHz), virtual disk (write rate avg.), memory(active)
#/usr/local/bin/stress --quiet --cpu 1 --io 1 --vm 1 --vm-bytes 128M --hdd 1 --timeout $duration &
/usr/local/bin/stress --quiet         --io 1 --vm 1 --vm-bytes 128M --hdd 1 --timeout $duration &

# Consume: Disk read (disk read rate always seems to be a small fraction of the write rate?)
fio --runtime=$duration --time_based  --name=random-read --rw=randread --directory=/tmp/data --minimal > /dev/null &

# Consume: network read/write While 'fio' is running in the background, copy files to the NAS VM
while [ $(jobs | grep 'Running.*fio' -c) -ne 0 ]
do
        echo "Copying: $srcFile"
        cp "$srcFile" /nas-drive/$destFile 
        cp /nas-drive/"$destFile" ~/junk.file
        #sleep 1s
done

# Clean up and exit
rm -f junk.file
rm -f /nas-drive/$destFile

stopped=$(date +"%x %r %Z")
echo "Complete at: $stopped, run time: $SECONDS secs"
