#!/bin/bash

## Function calculates number of bit in a netmask

mask2cidr() {
    nbits=0
    IFS=.
    for dec in $1 ; do
        case $dec in
            255) let nbits+=8;;
            254) let nbits+=7;;
            252) let nbits+=6;;
            248) let nbits+=5;;
            240) let nbits+=4;;
            224) let nbits+=3;;
            192) let nbits+=2;;
            128) let nbits+=1;;
            0);;
            *) echo "Error: $dec is not recognised"; exit 1
        esac
    done
    echo "$nbits"
}


## Extract Ip information from OVF Environment

IP=$(/usr/share/oem/bin/vmtoolsd --cmd "info-get guestinfo.ovfenv" | awk -F'[="|"]' '/network.IP_Address.primary/ {print $6}')
MASK=$(/usr/share/oem/bin/vmtoolsd --cmd "info-get guestinfo.ovfenv" | awk -F'[="|"]' '/network.Subnet_Mask.primary/ {print $6}')
GW=$(/usr/share/oem/bin/vmtoolsd --cmd "info-get guestinfo.ovfenv" | awk -F'[="|"]' '/network.Gateway.primary/ {print $6}')
DNS1=$(/usr/share/oem/bin/vmtoolsd --cmd "info-get guestinfo.ovfenv" | awk -F'[="|"]' '/network.DNS_Server.primary/ {print $6}')
DNS2=$(/usr/share/oem/bin/vmtoolsd --cmd "info-get guestinfo.ovfenv" | awk -F'[="|"]' '/network.DNS_Server.secondary/ {print $6}')
numbits=$(mask2cidr $MASK)

## Output the static.network file

if [ "$IP" = "" ]; then
  # Don't update if the file was configured by the registration wizard
  if [ -e "/etc/systemd/network/static.network" ]; then
    if ! grep -q "Configured by meter registration wizard" /etc/systemd/network/static.network; then
      echo -e "[Match]\nName=en*\n\n[Network]\nDHCP=yes" > /etc/systemd/network/static.network
      systemctl restart systemd-networkd
    fi
  fi
else
  echo -e "[Match]\nName=en*\n\n[Network]\nAddress=$IP/$numbits\nGateway=$GW\nDNS=$DNS1\nDNS=$DNS2\nDHCP=no" > /etc/systemd/network/static.network
  systemctl restart systemd-networkd
  ifconfig `ifconfig | grep -E 'en.+: ' | awk -F: '{print $1}'` $IP
fi

exit 0
