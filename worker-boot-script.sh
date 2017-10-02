#!/bin/bash

#worker-boot-script.sh

# install iRODS client
yum install --assumeyes wget
rpm --import https://packages.irods.org/irods-signing-key.asc
wget --quiet --output-document=/etc/yum.repos.d/renci-irods.yum.repo https://packages.irods.org/renci-irods.yum.repo
yum install --assumeyes irods-icommands


cp /home/cc/id_rsa_scidas /root/.ssh/id_rsa
cp /home/cc/id_rsa_scidas.pub /root/.ssh/id_rsa.pub

chmod 600 /root/.ssh/id_rsa.pub 
chmod 600 /root/.ssh/id_rsa 

cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

