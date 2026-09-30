zerombr
clearpart --all --initlabel
timezone UTC --utc
firewall --enabled --service=ssh
rootpw --lock
user --name=vekrona --password=vekrona --plaintext --groups=wheel
sshkey --username=vekrona "@SSH_PUBKEY@"
