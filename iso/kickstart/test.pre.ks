zerombr
clearpart --all --initlabel
bootloader --location=mbr --append="console=ttyS0 console=tty0"
autopart --type=btrfs --encrypted --luks-version=luks2 --passphrase=vekrona
timezone UTC --utc
firewall --enabled --service=ssh
rootpw --lock
user --name=vekrona --password=vekrona --plaintext --groups=wheel
sshkey --username=vekrona "@SSH_PUBKEY@"
