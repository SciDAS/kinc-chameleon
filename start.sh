#!/bin/bash

#Customize these vars
#Note: lease needs to be pre-created and have worker_count+1 nodes
LEASE_NAME='pruthx21'
KEY_NAME='pruth'
WORKER_COUNT=20

#These should mostly be left unchanged
NETWORK_NAME='network-vlan-3290'
MASTER_IMAGE='kinc-master.v2'
WORKER_IMAGE='kinc-worker.v2'
MASTER_INSTANCE_NAME='kinc-master'
WORKER_INSTANCE_PREFIX='kinc-w'
TOTAL_RESERVATION_COUNT=$((WORKER_COUNT + 1))/srv/jetstream-pegasus/bootstrap-worker.sh

RES_START=`date -u -v +2M  +"%Y-%m-%d %H:%M"`
RES_END=`date -u -v +1d +"%Y-%m-%d %H:%M"`

echo RES_START = $RES_START
echo RES_END   = $RES_END

#create the lease ---- This does not work and needs to be fixed
#climate lease-create --physical-reservation min=${TOTAL_RESERVATION_COUNT},max=${TOTAL_RESERVATION_COUNT},resource_properties='["=", "$node_type", "compute"]' --start-date "${RES_START}" --end-date "${RES_END}" $LEASE_NAME

#wait for lease to be active
LEASE_STATE=`climate lease-show $LEASE_NAME | grep action | awk '{ print $4 }'`
while [ "$LEASE_STATE" != "START" ]
do 
    LEASE_START=` climate lease-show pruth.1 | grep 'start_date' | awk '{ print $4 }'`
    echo Waiting for lease to become active.  Lease: $LEASE_NAME , State: $LEASE_STATE , Start_date: $LEASE_START 
    sleep 10
    LEASE_STATE=`climate lease-show $LEASE_NAME | grep action | awk '{ print $4 }'`
done
#LEASE_ID=`climate lease-show $LEASE_NAME | grep ' id' | awk '{ print $4 }'`
LEASE_ID=`climate lease-show -f value -c reservations $LEASE_NAME | grep '"id"' | awk -F "\"" '{ print $4}'`
echo Lease is ready.  Lease: $LEASE_NAME , State: $LEASE_STATE , Start_date: $LEASE_START , ID: $LEASE_ID

#get the network ID
NETWORK_ID=`neutron net-list | grep ${NETWORK_NAME} | awk '{ print $2 }'`

#Start condor sumbit/master
#nova boot --flavor baremetal --image CC-CentOS7 --key-name <key_name> --nic net-id=<sharednet1_id> --hint reservation=<reservation_id> my-advanced-instance
#nova boot --flavor baremetal --image ${MASTER_IMAGE} --key-name $KEY_NAME --nic net-id=${NETWORK_ID} --user-data master-boot-script.sh --hint reservation=${LEASE_ID} ${MASTER_INSTANCE_NAME}
nova boot --flavor baremetal --image ${MASTER_IMAGE} --key-name $KEY_NAME --nic net-id=${NETWORK_ID} --hint reservation=${LEASE_ID} ${MASTER_INSTANCE_NAME}

#start workers
for i in `seq 1 ${WORKER_COUNT}`;
do
    echo Starting worker $i
    nova boot --flavor baremetal --image ${WORKER_IMAGE} --key-name $KEY_NAME --nic net-id=${NETWORK_ID} --user-data worker-boot-script.sh --hint reservation=${LEASE_ID} ${WORKER_INSTANCE_PREFIX}$i
done    

#build /etc/hosts file
WORKER_IPS=""
cp hosts.base hosts.build
for i in `seq 1 ${WORKER_COUNT}`;
do   
   NODE_NAME=${WORKER_INSTANCE_PREFIX}$i

   NODE_IP=`nova list | grep $NODE_NAME | awk -F "[ \t]*|=|," '{print $13}'`
   while [ -z "$NODE_IP" ]; do
	sleep 10 
        echo Querying IP for $NODE_NAME 
        NODE_IP=`nova list | grep $NODE_NAME | awk -F "[ \t]*|=|," '{print $13}'` 
        if [ -z "$NODE_IP" ]; then
            echo Not Ready... sleeping 30 sec
            sleep 30
        else
            echo Found IP for $NODE_NAME $NODE_IP
        fi
   done
   echo Adding to hosts file $NODE_IP ${NODE_NAME}.novalocal ${NODE_NAME}
   echo $NODE_IP ${NODE_NAME}.novalocal ${NODE_NAME} >> hosts.build
   WORKER_IPS="${WORKER_IPS} $NODE_IP"
done

NODE_IP=`nova list | grep ${MASTER_INSTANCE_NAME} | awk -F "[ \t]*|=|," '{print $13}'`
while [ -z "$NODE_IP" ]; do 
         
        echo Querying IP for ${MASTER_INSTANCE_NAME}
        NODE_IP=`nova list | grep ${MASTER_INSTANCE_NAME} | awk -F "[ \t]*|=|," '{print $13}'`
	if [ -z "$NODE_IP" ]; then
            echo Not Ready... sleeping 30 sec
            sleep 30
        else
            echo Found IP for ${MASTER_INSTANCE_NAME} $NODE_IP
        fi 
done
echo Adding to hosts file $NODE_IP ${MASTER_INSTANCE_NAME}.novalocal ${MASTER_INSTANCE_NAME}
echo $NODE_IP ${MASTER_INSTANCE_NAME}.novalocal ${MASTER_INSTANCE_NAME} >> hosts.build

#assign floating ip to master
FLOATING_IP=`nova floating-ip-list | grep ext-net  | head -n1 | awk '{print $4}'`
echo Associated floating ip with $MASTER_INSTANCE_NAME $FLOATING_IP
nova floating-ip-associate $MASTER_INSTANCE_NAME  $FLOATING_IP



#Setup 
WORKER_NAMES=''
for i in `seq 1 ${WORKER_COUNT}`;
do 
  WORKER_NAMES="$WORKER_NAMES ${WORKER_INSTANCE_PREFIX}$i"
done
echo WORKER_NAMES: $WORKER_NAMES


#
scp hosts.build cc@${FLOATING_IP}:.
while [ $? -ne 0 ]; do echo Node not ready, retring after sleep 30; sleep 30; scp hosts.build cc@${FLOATING_IP}:.; done
scp master-boot-script.sh cc@${FLOATING_IP}:.
ssh cc@${FLOATING_IP} chmod +x master-boot-script.sh
echo Run this on the master:  sudo /home/cc/master-boot-script.sh $WORKER_NAMES
ssh cc@${FLOATING_IP} 'sudo /home/cc/master-boot-script.sh '$WORKER_NAMES

