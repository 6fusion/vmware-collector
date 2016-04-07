#!/bin/sh

MONGO="mongo:3.0.6"

docker inspect meterDB  >/dev/null 2>&1

if [ $? -eq 1 ]; then
    /usr/bin/docker pull $MONGO
    /usr/bin/docker run --name meterDB -v /data/db $MONGO /bin/true
    /usr/bin/docker run --name meter-init --volumes-from meterDB -v /usr/share/oem/init_mongo.js:/usr/share/oem/init_mongo.js $MONGO  &
    until docker inspect meter-init >/dev/null 2>&1
    do
        sleep 5
    done
    until docker exec meter-init  mongo 6fusion_meter_development -eval "db.isMaster()"
    do
        sleep 5
    done
    /usr/bin/docker exec  meter-init mongo /usr/share/oem/init_mongo.js
    /usr/bin/docker exec  meter-init mongod --shutdown
    /usr/bin/docker stop meter-init
    /usr/bin/docker rm meter-init
else
    echo "Database already initialized"
fi
