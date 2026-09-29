SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

VM_NAME := vekrona-test
VM_USER := vekrona
REPO_ROOT := $(abspath ..)
KS := $(abspath ks.cfg)
NETINSTALL_URL := https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/

OS_VARIANT := $(shell osinfo-query os 2>/dev/null | grep -E '^ *fedora[0-9]+' | sed -E 's/^ *(fedora[0-9]+).*/\1/' | sort -t a -k2 -n | tail -1)
ifeq ($(strip $(OS_VARIANT)),)
OS_VARIANT := fedora-rawhide
endif

.PHONY: deps create destroy console ssh test

deps:
	rpm -q virt-install >/dev/null 2>&1 || sudo dnf install -y virt-install
	rpm -q virt-viewer >/dev/null 2>&1 || sudo dnf install -y virt-viewer
	rpm -q libvirt-client >/dev/null 2>&1 || sudo dnf install -y libvirt-client
	rpm -q virt-install virt-viewer libvirt-client >/dev/null

create:
	curl -sfI "$(NETINSTALL_URL)" >/dev/null || { echo "netinstall tree unreachable: $(NETINSTALL_URL)" >&2; exit 1; }
	echo "using os-variant: $(OS_VARIANT)"
	virt-install \
		--name $(VM_NAME) \
		--memory 8192 \
		--vcpus 4 \
		--disk size=40 \
		--os-variant $(OS_VARIANT) \
		--location "$(NETINSTALL_URL)" \
		--initrd-inject "$(KS)" \
		--extra-args "inst.ks=file:/ks.cfg console=ttyS0" \
		--graphics none \
		--noautoconsole \
		--wait -1
	echo "install finished and the VM rebooted; run 'make test' next"

destroy:
	-virsh destroy $(VM_NAME)
	-virsh undefine $(VM_NAME) --remove-all-storage

console:
	virsh console $(VM_NAME)

ssh:
	@ip="$$(virsh domifaddr $(VM_NAME) 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
	[ -n "$$ip" ] || { echo "VM has no IPv4 address yet" >&2; exit 1; }; \
	ssh -o StrictHostKeyChecking=accept-new $(VM_USER)@$$ip

test:
	@ip=""; attempt=0; \
	until [ -n "$$ip" ] || [ $$attempt -ge 60 ]; do \
		ip="$$(virsh domifaddr $(VM_NAME) 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
		[ -n "$$ip" ] || sleep 5; \
		attempt=$$((attempt+1)); \
	done; \
	[ -n "$$ip" ] || { echo "VM did not get an IPv4 address" >&2; exit 1; }; \
	echo "vm ip: $$ip"; \
	attempt=0; \
	until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes $(VM_USER)@$$ip true 2>/dev/null; do \
		attempt=$$((attempt+1)); \
		[ $$attempt -lt 60 ] || { echo "ssh never became reachable" >&2; exit 1; }; \
		sleep 5; \
	done; \
	ssh $(VM_USER)@$$ip 'sudo loginctl enable-linger $(VM_USER)'; \
	rsync -a --exclude=.git "$(REPO_ROOT)/" $(VM_USER)@$$ip:vekrona/; \
	ssh $(VM_USER)@$$ip 'cd vekrona && ./install.sh --skip 10-nvidia'; \
	ssh $(VM_USER)@$$ip 'bash vekrona/vm/session-check.sh'; \
	snap_n="$$(ssh $(VM_USER)@$$ip 'sudo /home/$(VM_USER)/.local/bin/vekrona-snapshot vm-test')"; \
	ssh $(VM_USER)@$$ip "sudo /home/$(VM_USER)/.local/bin/vekrona-rollback --yes $$snap_n"; \
	ssh $(VM_USER)@$$ip 'sudo bash vekrona/vm/rollback-check.sh'; \
	virsh reboot $(VM_NAME); \
	attempt=0; \
	until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes $(VM_USER)@$$ip true 2>/dev/null; do \
		attempt=$$((attempt+1)); \
		[ $$attempt -lt 60 ] || { echo "ssh never came back after reboot" >&2; exit 1; }; \
		sleep 5; \
	done; \
	ssh $(VM_USER)@$$ip "findmnt / | grep -q 'subvol=/root'" || { echo "root is not mounted at subvol=/root after rollback+reboot" >&2; exit 1; }; \
	echo "vm test passed"
