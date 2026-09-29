SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

VM_NAME := vekrona-test
VM_USER := vekrona
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
KS := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))ks.cfg)
KS_TEMPLATE := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))ks.cfg.in)
NETINSTALL_URL := https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/

VIRSH := virsh --connect qemu:///system

VM_SSH_PUBKEY ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_rsa.pub $(HOME)/.ssh/*.pub))

OS_VARIANT = $(shell osinfo-query os 2>/dev/null | grep -E '^ *fedora[0-9]+' | sed -E 's/^ *(fedora[0-9]+).*/\1/' | sort -t a -k2 -n | tail -1)

.PHONY: deps create destroy console ssh test

deps:
	rpm -q virt-install >/dev/null 2>&1 || sudo dnf install -y virt-install
	rpm -q virt-viewer >/dev/null 2>&1 || sudo dnf install -y virt-viewer
	rpm -q libvirt-client >/dev/null 2>&1 || sudo dnf install -y libvirt-client
	rpm -q inotify-tools >/dev/null 2>&1 || sudo dnf install -y inotify-tools
	rpm -q virt-install virt-viewer libvirt-client inotify-tools >/dev/null
	sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
	$(VIRSH) net-info default >/dev/null 2>&1 || { echo "libvirt 'default' network not found" >&2; exit 1; }
	active="$$($(VIRSH) net-info default | awk -F': *' '/^Active/{print $$2}')"; \
	[ "$$active" = "yes" ] || sudo $(VIRSH) net-start default
	autostart="$$($(VIRSH) net-info default | awk -F': *' '/^Autostart/{print $$2}')"; \
	[ "$$autostart" = "yes" ] || sudo $(VIRSH) net-autostart default
	groups "$$USER" | grep -qw libvirt || { sudo usermod -aG libvirt "$$USER"; echo "added $$USER to the libvirt group; log out and back in for this to take effect" >&2; }

$(KS): $(KS_TEMPLATE) $(VM_SSH_PUBKEY)
	@[ -n "$(VM_SSH_PUBKEY)" ] || { echo "no SSH public key found under $(HOME)/.ssh; set VM_SSH_PUBKEY=/path/to/key.pub" >&2; exit 1; }
	@[ -r "$(VM_SSH_PUBKEY)" ] || { echo "SSH public key not readable: $(VM_SSH_PUBKEY)" >&2; exit 1; }
	SSH_PUBKEY="$$(cat "$(VM_SSH_PUBKEY)")" python3 -c 'import os, sys; open(sys.argv[2], "w").write(open(sys.argv[1]).read().replace("@SSH_PUBKEY@", os.environ["SSH_PUBKEY"]))' "$(KS_TEMPLATE)" "$(KS)"

create: $(KS)
	@os_variant="$(OS_VARIANT)"; \
	[ -n "$$os_variant" ] || os_variant="fedora-rawhide"; \
	curl -sfI "$(NETINSTALL_URL)" >/dev/null || { echo "netinstall tree unreachable: $(NETINSTALL_URL)" >&2; exit 1; }; \
	echo "using os-variant: $$os_variant"; \
	virt-install \
		--connect qemu:///system \
		--name "$(VM_NAME)" \
		--memory 8192 \
		--vcpus 4 \
		--disk size=40 \
		--os-variant "$$os_variant" \
		--network network=default \
		--location "$(NETINSTALL_URL)" \
		--initrd-inject "$(KS)" \
		--extra-args "inst.ks=file:/ks.cfg console=ttyS0" \
		--graphics none \
		--noautoconsole \
		--noreboot \
		--wait -1; \
	$(VIRSH) start "$(VM_NAME)"; \
	echo "install finished and the VM started; run 'make test' next"

destroy:
	-$(VIRSH) destroy "$(VM_NAME)"
	-$(VIRSH) undefine "$(VM_NAME)" --remove-all-storage

console:
	$(VIRSH) console "$(VM_NAME)"

ssh:
	@ip="$$($(VIRSH) domifaddr "$(VM_NAME)" --source lease 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
	[ -n "$$ip" ] || { echo "VM has no IPv4 address yet" >&2; exit 1; }; \
	ssh -o StrictHostKeyChecking=accept-new "$(VM_USER)@$$ip"

test:
	@bridge="$$($(VIRSH) net-info default | awk -F': *' '/^Bridge/{print $$2}')"; \
	[ -n "$$bridge" ] || { echo "could not determine bridge for network 'default'" >&2; exit 1; }; \
	status_file="/var/lib/libvirt/dnsmasq/$$bridge.status"; \
	ip=""; attempt=0; \
	until [ -n "$$ip" ] || [ $$attempt -ge 60 ]; do \
		ip="$$($(VIRSH) domifaddr "$(VM_NAME)" --source lease 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
		if [ -z "$$ip" ]; then \
			if [ -e "$$status_file" ] && [ -r "$$status_file" ]; then \
				inotifywait -q -t 5 -e modify,close_write "$$status_file" >/dev/null 2>&1 || true; \
			elif [ -e "$$status_file" ]; then \
				sudo inotifywait -q -t 5 -e modify,close_write "$$status_file" >/dev/null 2>&1 || true; \
			else \
				inotifywait -q -t 5 -e create "$$(dirname "$$status_file")" >/dev/null 2>&1 || true; \
			fi; \
		fi; \
		attempt=$$((attempt + 1)); \
	done; \
	[ -n "$$ip" ] || { echo "VM did not get an IPv4 address" >&2; exit 1; }; \
	echo "vm ip: $$ip"; \
	ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"; \
	ssh $$ssh_opts -o ConnectionAttempts=60 "$(VM_USER)@$$ip" true \
		|| { echo "ssh never became reachable" >&2; exit 1; }; \
	ssh $$ssh_opts "$(VM_USER)@$$ip" 'sudo loginctl enable-linger $(VM_USER)'; \
	rsync -a --exclude=.git -e "ssh $$ssh_opts" "$(REPO_ROOT)/" "$(VM_USER)@$$ip:vekrona/"; \
	ssh $$ssh_opts "$(VM_USER)@$$ip" 'cd vekrona && ./install.sh --skip 10-nvidia'; \
	ssh $$ssh_opts "$(VM_USER)@$$ip" 'bash vekrona/vm/session-check.sh'; \
	snap_n="$$(ssh $$ssh_opts "$(VM_USER)@$$ip" 'sudo /home/$(VM_USER)/.local/bin/vekrona-snapshot vm-test')"; \
	ssh $$ssh_opts "$(VM_USER)@$$ip" "sudo /home/$(VM_USER)/.local/bin/vekrona-rollback --yes $$snap_n"; \
	old_boot_id="$$(ssh $$ssh_opts "$(VM_USER)@$$ip" cat /proc/sys/kernel/random/boot_id)"; \
	$(VIRSH) reboot "$(VM_NAME)"; \
	new_boot_id=""; attempt=0; \
	until [ -n "$$new_boot_id" ] && [ "$$new_boot_id" != "$$old_boot_id" ]; do \
		[ $$attempt -lt 5 ] || { echo "vm did not come back with a new boot_id after reboot" >&2; exit 1; }; \
		new_boot_id="$$(ssh $$ssh_opts -o ConnectionAttempts=60 "$(VM_USER)@$$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"; \
		attempt=$$((attempt + 1)); \
	done; \
	ssh $$ssh_opts "$(VM_USER)@$$ip" "sudo bash vekrona/vm/rollback-check.sh $$snap_n"; \
	echo "vm test passed"
