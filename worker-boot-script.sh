#!/bin/bash

#worker-boot-script.sh

cp /home/cc/id_rsa_scidas /root/.ssh/id_rsa
cp /home/cc/id_rsa_scidas.pub /root/.ssh/id_rsa.pub

chmod 600 /root/.ssh/id_rsa.pub 
chmod 600 /root/.ssh/id_rsa 

cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

