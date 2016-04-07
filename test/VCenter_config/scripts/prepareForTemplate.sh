#!/bin/sh
# Prepare VM to become a template
# From: https://lonesysadmin.net/2013/03/26/preparing-linux-template-vms/

echo "Step 0: Stop logging services."
/sbin/service rsyslog stop
/sbin/service auditd stop

echo "Step 1: Remove old kernels"
/bin/package-cleanup --oldkernels --count=1

echo "Step 2: Clean out yum."
/usr/bin/yum clean all

echo "Step 3: Force the logs to rotate & remove old logs we don’t need."
/usr/sbin/logrotate --force /etc/logrotate.conf
/bin/rm –f /var/log/*-???????? /var/log/*.gz
/bin/rm -f /var/log/dmesg.old
/bin/rm -rf /var/log/anaconda

echo "Step 4: Truncate the audit logs (and other logs we want to keep placeholders for)."
/bin/cat /dev/null > /var/log/audit/audit.log
/bin/cat /dev/null > /var/log/wtmp
/bin/cat /dev/null > /var/log/lastlog
/bin/cat /dev/null > /var/log/grubby

echo "Step 5: Remove the udev persistent device rules."
/bin/rm -f /etc/udev/rules.d/70*

echo "Step 6: Remove the traces of the template MAC address and UUIDs."
/bin/sed -i '/^(HWADDR|UUID)=/d' /etc/sysconfig/network-scripts/ifcfg-eth0

echo "Step 7: Clean /tmp out."
/bin/rm –rf /tmp/*
/bin/rm –rf /var/tmp/*

echo "Step 8: (skipping this step) Remove the SSH host keys."
#/bin/rm –f /etc/ssh/*key*

echo "Step 9: Remove the root user’s shell history."
/bin/rm -f ~root/.bash_history
unset HISTFILE

echo "Step 10: Remove the root user’s SSH history & other cruft."
/bin/rm -rf ~root/.ssh/
/bin/rm -f ~root/anaconda-ks.cfg

echo "Step 11: Zero out all free space, then use storage vMotion to re-thin the VM"
# Determine the version of RHEL
#COND=`grep -i Taroon /etc/redhat-release`
#if [ "$COND" = "" ]; then
#        export PREFIX="/usr/sbin"
#else
        export PREFIX="/sbin"
#fi

FileSystem=`grep ext /etc/mtab| awk -F" " '{ print $2 }'`

for i in $FileSystem
do
        echo "Path: $i"
        number=`df -B 512 $i | awk -F" " '{print $3}' | grep -v Used`
        echo "Number: $number"
        percent=$(echo "scale=0;$number*98/100" | bc)
        echo "Percent: $percent"
        dd count=$percent if=/dev/zero of=$i/zf
        /bin/sync
        sleep 15
        rm -f $i/zf
done

VolumeGroup=`$PREFIX/vgdisplay | grep Name | awk -F" " '{ print $3 }'`

for j in $VolumeGroup
do
        echo $j
        $PREFIX/lvcreate -l `$PREFIX/vgdisplay $j | grep Free | awk -F" " '{ print $5 }'` -n zero $j
        if [ -a /dev/$j/zero ]; then
                cat /dev/zero > /dev/$j/zero
                /bin/sync
                sleep 15
                $PREFIX/lvremove -f /dev/$j/zero
        fi
done