#!/bin/bash
# Run on test-k8s-m1 as root. Sets up passwordless SSH, unique machine-id, swap off on all 4 nodes.
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
for h in test-k8s-m1 test-k8s-m2 test-k8s-m3 test-k8s-w1; do
  echo "=== $h ==="
  ssh-copy-id -o StrictHostKeyChecking=accept-new root@$h
  ssh $h 'rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup; swapoff -a; sed -i "/swap/d" /etc/fstab; hostname; nproc; free -g | awk "/Mem/{print \$2\" GB RAM\"}"; df -h /var | tail -1; systemctl is-active firewalld'
done
