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
	rpm -q virt-install virt-viewer libvirt-client >/dev/null
	sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
	$(VIRSH) net-info default >/dev/null 2>&1 || { echo "libvirt 'default' network not found" >&2; exit 1; }
	active="$$($(VIRSH) net-info default | awk -F': *' '/^Active/{print $$2}')"; \
	[ "$$active" = "yes" ] || sudo $(VIRSH) net-start default
	autostart="$$($(VIRSH) net-info default | awk -F': *' '/^Autostart/{print $$2}')"; \
	[ "$$autostart" = "yes" ] || sudo $(VIRSH) net-autostart default
	groups "$$USER" | grep -qw libvirt || { sudo usermod -aG libvirt "$$USER"; echo "added $$USER to the libvirt group; log out and back in for this to take effect" >&2; }

$(KS): $(KS_TEMPLATE)
	@[ -n "$(VM_SSH_PUBKEY)" ] || { echo "no SSH public key found under $(HOME)/.ssh; set VM_SSH_PUBKEY=/path/to/key.pub" >&2; exit 1; }
	@[ -r "$(VM_SSH_PUBKEY)" ] || { echo "SSH public key not readable: $(VM_SSH_PUBKEY)" >&2; exit 1; }
	sed "s#@SSH_PUBKEY@#$$(cat "$(VM_SSH_PUBKEY)")#" "$(KS_TEMPLATE)" > "$(KS)"

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
		--wait -1; \
	$(VIRSH) start "$(VM_NAME)"; \
	$(VIRSH) event --domain "$(VM_NAME)" --event lifecycle --timeout 300 >/dev/null 2>&1 || true; \
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
	@ip=""; attempt=0; \
	until [ -n "$$ip" ] || [ $$attempt -ge 60 ]; do \
		ip="$$($(VIRSH) domifaddr "$(VM_NAME)" --source lease 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
		[ -n "$$ip" ] || $(VIRSH) event --domain "$(VM_NAME)" --all --timeout 2 >/dev/null 2>&1 || true; \
		attempt=$$((attempt + 1)); \
	done; \
	[ -n "$$ip" ] || { echo "VM did not get an IPv4 address" >&2; exit 1; }; \
	echo "vm ip: $$ip"; \
	ssh -o StrictHostKeyChecking=accept-new -o ConnectionAttempts=60 -o ConnectTimeout=5 -o BatchMode=yes "$(VM_USER)@$$ip" true \
		|| { echo "ssh never became reachable" >&2; exit 1; }; \
	ssh "$(VM_USER)@$$ip" 'sudo loginctl enable-linger $(VM_USER)'; \
	rsync -a --exclude=.git "$(REPO_ROOT)/" "$(VM_USER)@$$ip:vekrona/"; \
	ssh "$(VM_USER)@$$ip" 'cd vekrona && ./install.sh --skip 10-nvidia'; \
	ssh "$(VM_USER)@$$ip" 'bash vekrona/vm/session-check.sh'; \
	snap_n="$$(ssh "$(VM_USER)@$$ip" 'sudo /home/$(VM_USER)/.local/bin/vekrona-snapshot vm-test')"; \
	ssh "$(VM_USER)@$$ip" "sudo /home/$(VM_USER)/.local/bin/vekrona-rollback --yes $$snap_n"; \
	old_boot_id="$$(ssh "$(VM_USER)@$$ip" cat /proc/sys/kernel/random/boot_id)"; \
	$(VIRSH) reboot "$(VM_NAME)"; \
	new_boot_id=""; attempt=0; \
	until [ -n "$$new_boot_id" ] && [ "$$new_boot_id" != "$$old_boot_id" ]; do \
		[ $$attempt -lt 60 ] || { echo "vm did not come back with a new boot_id after reboot" >&2; exit 1; }; \
		new_boot_id="$$(ssh -o StrictHostKeyChecking=accept-new -o ConnectionAttempts=60 -o ConnectTimeout=5 -o BatchMode=yes "$(VM_USER)@$$ip" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"; \
		[ "$$new_boot_id" != "$$old_boot_id" ] || $(VIRSH) event --domain "$(VM_NAME)" --all --timeout 2 >/dev/null 2>&1 || true; \
		attempt=$$((attempt + 1)); \
	done; \
	ssh "$(VM_USER)@$$ip" "sudo bash vekrona/vm/rollback-check.sh $$snap_n"; \
	echo "vm test passed"
