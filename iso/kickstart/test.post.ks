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
systemctl enable sshd
%end
