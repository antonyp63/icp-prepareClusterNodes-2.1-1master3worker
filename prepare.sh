#!/bin/bash

#COMMON ENV VARIABLES
BIN_DOWNLOAD_DIR="/tmp/icp-ee"
#INSTALL_DIR="/opt/ibm-cloud-private-2.1.0-beta"

#install sshpass
tar zxvf /tmp/icp/boot/sshpass-1.06.tar.gz -C /tmp/
cd /tmp/sshpass-1.06 && ./configure
cd /tmp/sshpass-1.06 && make
cd /tmp/sshpass-1.06 && make install



################ Set up the installation environment ###########

#download binaries
mkdir -p ${BIN_DOWNLOAD_DIR}

#step 2 - download installer (2.1)
wget -P ${BIN_DOWNLOAD_DIR} ${INSTALLER_BASEURL}/${INSTALLER_FILENAME}

#step 3 - load images into Docker
cd ${BIN_DOWNLOAD_DIR} && tar xf ${INSTALLER_FILENAME} -O | sudo docker load

#step 4 - create working directory for installation
mkdir -p ${INSTALL_DIR}

#step 5 & 6
cd ${INSTALL_DIR} && sudo docker run -v $(pwd):/data -e LICENSE=accept ${IMAGE_NAME} cp -r cluster /data

#step 7 - gen key can copy pub key across cluster nodes
ssh-keygen -b 4096 -t rsa -f ~/.ssh/master.id_rsa -N ""
cat ~/.ssh/master.id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys

if [[ ! -z ${MASTER_1_IP+x} ]]; then
	echo "Copy SSH key to Master Node 1"
	echo ${MASTER_1_IP}
	ssh-keyscan ${MASTER_1_IP} | sudo tee -a /root/.ssh/known_hosts
	sshpass -p ${SSH_ROOT_PWD} scp ~/.ssh/master.id_rsa.pub root@${MASTER_1_IP}:~/.ssh/master.id_rsa.pub
	sleep 2
	sshpass -p ${SSH_ROOT_PWD} ssh -tt root@${MASTER_1_IP} 'cat ~/.ssh/master.id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys ; echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config ; sysctl -w vm.max_map_count=262144'
	sleep 2
fi

if [[ ! -z ${WORKER_1_IP+x} ]]; then
	echo "Copy SSH key to Worker Node 1"
	echo ${WORKER_1_IP}
	ssh-keyscan ${WORKER_1_IP} | sudo tee -a /root/.ssh/known_hosts
	sshpass -p ${SSH_ROOT_PWD} scp ~/.ssh/master.id_rsa.pub root@${WORKER_1_IP}:~/.ssh/master.id_rsa.pub
	sleep 2
	sshpass -p ${SSH_ROOT_PWD} ssh -tt root@${WORKER_1_IP} 'cat ~/.ssh/master.id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys ; echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config ; sysctl -w vm.max_map_count=262144'
	sleep 2
fi

if [[ ! -z ${WORKER_2_IP+x} ]]; then
	echo "Copy SSH key to Worker Node 2"
	echo ${WORKER_2_IP}
	ssh-keyscan ${WORKER_2_IP} | sudo tee -a /root/.ssh/known_hosts
	sshpass -p ${SSH_ROOT_PWD} scp ~/.ssh/master.id_rsa.pub root@${WORKER_2_IP}:~/.ssh/master.id_rsa.pub
	sleep 2
	sshpass -p ${SSH_ROOT_PWD} ssh -tt root@${WORKER_2_IP} 'cat ~/.ssh/master.id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys ; echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config ; sysctl -w vm.max_map_count=262144'
	sleep 2
fi

if [[ ! -z ${WORKER_3_IP+x} ]]; then
	echo "Copy SSH key to Worker Node 3"
	echo ${WORKER_3_IP}
	ssh-keyscan ${WORKER_3_IP} | sudo tee -a /root/.ssh/known_hosts
	sshpass -p ${SSH_ROOT_PWD} scp ~/.ssh/master.id_rsa.pub root@${WORKER_3_IP}:~/.ssh/master.id_rsa.pub
	sleep 2
	sshpass -p ${SSH_ROOT_PWD} ssh -tt root@${WORKER_3_IP} 'cat ~/.ssh/master.id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys ; echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config ; sysctl -w vm.max_map_count=262144'
	sleep 2
fi


#step 8 - modify hosts
tee ${INSTALL_DIR}/cluster/hosts <<-EOF
[master]
${MASTER_1_IP}

[worker]
${WORKER_1_IP}
${WORKER_2_IP}
${WORKER_3_IP}

[proxy]
${MASTER_1_IP}

EOF

#step 9 - Setting up SSH Key
cp ~/.ssh/master.id_rsa ${INSTALL_DIR}/cluster/ssh_key
chmod 400 ${INSTALL_DIR}/cluster/ssh_key

#step 10
mkdir -p ${INSTALL_DIR}/cluster/images
mv ${BIN_DOWNLOAD_DIR}/${INSTALLER_FILENAME} ${INSTALL_DIR}/cluster/images/

#######  Customize your cluster ######

#step 0 - modify config.yaml
tee -a ${INSTALL_DIR}/cluster/config.yaml <<-EOF

#replace api server port to avoid conflict with Pure mgmt port
kube_apiserver_insecure_port: 10888
cluster_name: icpcluster

#IP over IP mode
calico_ipip_enabled: ${CALICO_IPIP_ENABLED}

EOF

#step 1 - Network settings
if [[ -e "/etc/db2vip.conf" ]]; then
	. /etc/db2vip.conf
	tee -a ${INSTALL_DIR}/cluster/config.yaml <<-EOF

		#HA settings
		vip_iface: eth1
		cluster_vip: ${VIP_CLUSTER}

		# Proxy settings
		proxy_vip_iface: eth1
		proxy_vip: ${VIP_PROXY}

	EOF
	tee -a ${INSTALL_DIR}/cluster/config.yaml <<-EOF

	cluster_access_ip: ${MASTER_1_IP}
	proxy_access_ip: ${MASTER_1_IP}

	EOF
fi

#step 2 (optional) Enable Kibana
if $LOGGING_ENABLED; then
	tee -a ${INSTALL_DIR}/cluster/config.yaml <<-EOF
		#enable logging feature
		# Logging service configuration
		logging:
		 maxAge: 1
		 storage:
		   es:
		     size: 20Gi
		     path: /opt/ibm/cfc/logging/elasticsearch
		   ls:
		     size: 5Gi
		     path: /opt/ibm/cfc/logging/logstash
		 kibana:
		   install: true
	EOF
fi

#step 5 (optional) Enable Vulnerability Advisor
if $VULNERABILITY_ADVISOR; then
	tee -a ${INSTALL_DIR}/cluster/config.yaml <<-EOF
	## Disabled Management Services Settings
	disabled_management_services: [""]
EOF
fi


############# Deploy the environment ###########

#step 1 & 2 - install
cd ${INSTALL_DIR}/cluster && docker run --net=host -t -e LICENSE=accept -v $(pwd):/installer/cluster ${IMAGE_NAME} install


############# Post installation tasks ############

cat > /tmp/icp/volumes.yaml <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
   name: cam-logs-pv
spec:
   capacity:
      storage: 10Gi
   accessModes:
      - ReadWriteMany
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/CAM_logs
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: cam-mongo-pv
spec:
   capacity:
      storage: 15Gi
   accessModes:
      - ReadWriteMany
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/CAM_dbs
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: dovol1
spec:
   capacity:
      storage: 1Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/dovol1
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: dovol2
spec:
   capacity:
      storage: 1Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/dovol2
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: dovol3
spec:
   capacity:
      storage: 1Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/dovol3
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: dovol4
spec:
   capacity:
      storage: 1Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/dovol4
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: jenkins-home
spec:
   capacity:
      storage: 1Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Recycle
   nfs:
      path: /export/jenkins-home
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: db2vol1
spec:
   capacity:
      storage: 10Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Retain
   nfs:
      path: /export/db2vol1
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: mqvol1
spec:
   capacity:
      storage: 3Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Retain
   nfs:
      path: /export/mqvol1
      server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolume
metadata:
   name: redisvol1
spec:
   capacity:
      storage: 8Gi
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Retain
   nfs:
      path: /export/redisvol1
      server: ${NFS_SERVER_IP}
EOF
