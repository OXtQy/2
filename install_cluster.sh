#!/bin/bash
# Run on test-k8s-m1 as root in /var/OpenScapeUC, after prep_nodes.sh and after the big files are present.
set -e
cd /var/OpenScapeUC
S=./k8s_cluster_multienv_setup-V3.1.6.sh
echo "### distribute files"; ./deploy_cluster-V3.1.6.sh prepare airgapped scripts images firewall
echo "### node1";            $S --airgapped node1
echo "### token into config.env"
sed -i '/^TOKEN=/d' config.env
echo "TOKEN=\"$(cat /var/lib/rancher/rke2/server/node-token)\"" >> config.env
./deploy_cluster-V3.1.6.sh scripts
echo "### node2"; ssh test-k8s-m2 "cd /var/OpenScapeUC && $S --airgapped node2"
echo "### node3"; ssh test-k8s-m3 "cd /var/OpenScapeUC && $S --airgapped node3"
echo "### workers"; ./deploy_cluster-V3.1.6.sh install
echo "### stack (node3)"; ssh test-k8s-m3 "cd /var/OpenScapeUC && $S --airgapped stack"
kubectl get nodes
