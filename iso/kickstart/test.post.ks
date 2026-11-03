%post --erroronfail --log=/root/vekrona-test-tuning.log
set -euo pipefail
cat > /etc/sudoers.d/vekrona-test <<'EOF'
vekrona ALL=(ALL) NOPASSWD: ALL
Defaults:vekrona !authenticate
EOF
chmod 0440 /etc/sudoers.d/vekrona-test
visudo -cf /etc/sudoers.d/vekrona-test
install -d /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/virtio-gpu-cannot-resume.conf <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
# iso/qemu-test.sh drives the guest over ssh. The marker keeps openssh-server through the install; the drop-in takes keys only
# (the test user's password is public).
systemctl enable sshd
install -d /etc/vekrona
install -m 0644 /dev/null /etc/vekrona/keep-sshd
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-vekrona-test.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
%end
