#!/bin/bash

#master-boot-script.sh

# install iRODS client
yum install --assumeyes wget
rpm --import https://packages.irods.org/irods-signing-key.asc
wget --quiet --output-document=/etc/yum.repos.d/renci-irods.yum.repo https://packages.irods.org/renci-irods.yum.repo
yum install --assumeyes irods-icommands

#setup paswordless ssh to workers
cp /home/cc/id_rsa_scidas /root/.ssh/id_rsa
cp /home/cc/id_rsa_scidas.pub /root/.ssh/id_rsa.pub
chmod 600 /root/.ssh/id_rsa.pub       
chmod 600 /root/.ssh/id_rsa                          
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

#setup workflow keys
ssh-keygen -t rsa -N "" -f /home/cc/.ssh/workflow
chown cc:cc /home/cc/.ssh/workflow
cat /home/cc/.ssh/workflow.pub >> /home/cc/.ssh/authorized_keys

#tweak condor config
MASTER_IP=`ifconfig eno1 | grep 'inet '  | awk '{print $2}'`
echo > /etc/condor/config.d/99-local.conf
echo NETWORK_INTERFACE = ${MASTER_IP} >> /etc/condor/config.d/99-local.conf 
echo >> /etc/condor/config.d/99-local.conf 

echo > /etc/condor/config.d/50-master.conf
echo CONDOR_HOST = ${MASTER_IP} >> /etc/condor/config.d/50-master.conf
echo >> /etc/condor/config.d/50-master.conf



#After /home/cc/hosts exists copy it everywhere
cp /home/cc/hosts.build /etc/hosts





for node in $*; do
   echo Processing $node
   scp -o StrictHostKeyChecking=no  /home/cc/hosts.build $node:/etc/hosts
   while [ $? -ne 0 ]; do echo Node not ready, retring after sleep 30; sleep 30; scp -o StrictHostKeyChecking=no  /home/cc/hosts.build $node:/etc/hosts; done
   ssh -o StrictHostKeyChecking=no $node 'echo CONDOR_HOST = '${MASTER_IP}' > /etc/condor/config.d/50-master.conf'
done

#setup master
/srv/jetstream-pegasus/bootstrap-master.sh

for node in $*; do
   echo Setting up $node
   /srv/jetstream-pegasus/bootstrap-worker.sh $node
done

systemctl restart condor

for node in $*; do
   echo Processing $node
   ssh -o StrictHostKeyChecking=no $node 'echo CONDOR_HOST = '${MASTER_IP}' > /etc/condor/config.d/50-master.conf'
   ssh -o StrictHostKeyChecking=no $node 'sudo systemctl restart condor'
done

