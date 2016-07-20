#!/bin/sh

if [[ $# -ne 3 ]] ; then
    echo 'Get OnPrem machine counts for each infratructure'
    echo 'Usage: org start_inf end_inf'
    exit 1
fi

org=$1
start_inf=$2
end_inf=$3

for ((inf=$start_inf; inf<=$end_inf; inf++)) 
do
   mach=`./uc6api_get.rb -t mach -i $org $inf -ancq -l 100000`
   echo "Org:" $org "Inf:" $inf "Machines:" $mach
done
