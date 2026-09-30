SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

VM_NAME := vekrona-test
VM_USER := vekrona

_SAFE_NAME_CHARS := a b c d e f g h i j k l m n o p q r s t u v w x y z \
                     A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
                     0 1 2 3 4 5 6 7 8 9 - _ .
check-safe-name = $(strip $(eval _san := $(1))$(foreach c,$(_SAFE_NAME_CHARS),$(eval _san := $(subst $(c),,$(_san))))$(_san))

ifeq ($(strip $(VM_NAME)),)
$(error VM_NAME must not be empty)
endif
ifneq ($(call check-safe-name,$(VM_NAME)),)
$(error VM_NAME '$(VM_NAME)' contains characters outside [A-Za-z0-9._-])
endif
ifneq ($(filter -% .% _%,$(VM_NAME)),)
$(error VM_NAME '$(VM_NAME)' must start with a letter or digit)
endif

ifeq ($(strip $(VM_USER)),)
$(error VM_USER must not be empty)
endif
ifneq ($(call check-safe-name,$(VM_USER)),)
$(error VM_USER '$(VM_USER)' contains characters outside [A-Za-z0-9._-])
endif
ifneq ($(filter -% .% _%,$(VM_USER)),)
$(error VM_USER '$(VM_USER)' must start with a letter or digit)
endif

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
KS := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))ks-$(VM_NAME).cfg)
KS_TEMPLATE := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))ks.cfg.in)
OS_VARIANT_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))os-variant.sh)
INSTALL_TREE_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))install-tree.sh)
KEYMAP_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))keymap.sh)
WAIT_FOR_IP_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))wait-for-ip.sh)
WAIT_FOR_REBOOT_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))wait-for-reboot.py)
FEDORA_RELEASE := 44
SERIAL_LOG := /var/log/libvirt/qemu/$(VM_NAME)-serial0.log

VIRSH := virsh --connect qemu:///system

HARNESS_METADATA_URI := urn:vekrona:harness
HARNESS_METADATA_KEY := vekrona
HARNESS_METADATA_XML := <harness xmlns="urn:vekrona:harness">vekrona-vm-makefile</harness>

IP_WAIT_TIMEOUT ?= 120
REBOOT_EVENT_TIMEOUT ?= 60
AGENT_RECONNECT_TIMEOUT ?= 300
SSH_CONNECT_ATTEMPTS ?= 60

VM_SSH_PUBKEY ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_rsa.pub $(HOME)/.ssh/*.pub))
export VM_SSH_PUBKEY

HARNESS_SSH_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))).ssh)
HARNESS_KEY := $(HARNESS_SSH_DIR)/id_ed25519
HARNESS_PUBKEY := $(HARNESS_KEY).pub

SSH_OPTS := -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i $(HARNESS_KEY) -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

export TEXT KEYS OUT

.PHONY: deps create destroy adopt console ssh test screenshot viewer type key require-harness-key

deps:
	rpm -q virt-install >/dev/null 2>&1 || sudo dnf install -y virt-install
	rpm -q virt-viewer >/dev/null 2>&1 || sudo dnf install -y virt-viewer
	rpm -q libvirt-client >/dev/null 2>&1 || sudo dnf install -y libvirt-client
	rpm -q inotify-tools >/dev/null 2>&1 || sudo dnf install -y inotify-tools
	rpm -q ImageMagick >/dev/null 2>&1 || sudo dnf install -y ImageMagick
	rpm -q python3-libvirt >/dev/null 2>&1 || sudo dnf install -y python3-libvirt
	rpm -q virt-install virt-viewer libvirt-client inotify-tools ImageMagick python3-libvirt >/dev/null
	sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
	$(VIRSH) net-info default >/dev/null 2>&1 || { echo "libvirt 'default' network not found" >&2; exit 1; }
	active="$$($(VIRSH) net-info default | awk -F': *' '/^Active/{print $$2}')"; \
	[ "$$active" = "yes" ] || sudo $(VIRSH) net-start default
	autostart="$$($(VIRSH) net-info default | awk -F': *' '/^Autostart/{print $$2}')"; \
	[ "$$autostart" = "yes" ] || sudo $(VIRSH) net-autostart default
	groups "$$USER" | grep -qw libvirt || { sudo usermod -aG libvirt "$$USER"; echo "added $$USER to the libvirt group; log out and back in for this to take effect" >&2; }

$(HARNESS_KEY) $(HARNESS_PUBKEY) &:
	mkdir -p -m 700 "$(HARNESS_SSH_DIR)"
	ssh-keygen -t ed25519 -N '' -C vekrona-vm-harness -f "$(HARNESS_KEY)" >/dev/null

$(KS): $(KS_TEMPLATE) $(VM_SSH_PUBKEY) $(HARNESS_PUBKEY)
	@[ -n "$${VM_SSH_PUBKEY:-}" ] || { echo "no SSH public key found under $(HOME)/.ssh; set VM_SSH_PUBKEY=/path/to/key.pub" >&2; exit 1; }
	@[ -r "$$VM_SSH_PUBKEY" ] || { echo "SSH public key not readable: $$VM_SSH_PUBKEY" >&2; exit 1; }
	SSH_PUBKEY="$$(cat "$$VM_SSH_PUBKEY")" HARNESS_PUBKEY="$$(cat "$(HARNESS_PUBKEY)")" VM_NAME="$(VM_NAME)" python3 -c 'import os, sys; text = open(sys.argv[1]).read(); text = text.replace("@SSH_PUBKEY@", os.environ["SSH_PUBKEY"]); text = text.replace("@HARNESS_PUBKEY@", os.environ["HARNESS_PUBKEY"]); text = text.replace("@VM_NAME@", os.environ["VM_NAME"]); open(sys.argv[2], "w").write(text)' "$(KS_TEMPLATE)" "$(KS)"

create: $(KS)
	@os_variant="$$(bash "$(OS_VARIANT_SCRIPT)" "$(FEDORA_RELEASE)")"; \
	tree_url="$$(bash "$(INSTALL_TREE_SCRIPT)" "$(FEDORA_RELEASE)")"; \
	echo "using os-variant: $$os_variant"; \
	echo "using install tree: $$tree_url"; \
	virt-install \
		--connect qemu:///system \
		--name "$(VM_NAME)" \
		--memory 8192 \
		--vcpus 4 \
		--disk size=40 \
		--os-variant "$$os_variant" \
		--network network=default \
		--channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
		--location "$$tree_url" \
		--initrd-inject "$(KS)" \
		--extra-args "inst.ks=file:/ks.cfg console=ttyS0" \
		--graphics spice,listen=127.0.0.1 \
		--video virtio \
		--serial pty,log.file=$(SERIAL_LOG),log.append=off \
		--noautoconsole \
		--noreboot \
		--wait -1; \
	$(VIRSH) metadata "$(VM_NAME)" "$(HARNESS_METADATA_URI)" --key $(HARNESS_METADATA_KEY) --set '$(HARNESS_METADATA_XML)' --config; \
	$(VIRSH) start "$(VM_NAME)"; \
	echo "install finished and the VM started; serial console logged to $(SERIAL_LOG); run 'make test' next"

adopt:
	@[ -f "$(KS)" ] || { echo "refusing to adopt '$(VM_NAME)': no generated kickstart at $(KS); only a domain this harness created (evidenced by its ks-<name>.cfg) can be adopted" >&2; exit 1; }
	@$(VIRSH) dominfo "$(VM_NAME)" >/dev/null || { echo "domain '$(VM_NAME)' does not exist" >&2; exit 1; }
	@$(VIRSH) metadata "$(VM_NAME)" "$(HARNESS_METADATA_URI)" --key $(HARNESS_METADATA_KEY) --set '$(HARNESS_METADATA_XML)' --config; \
	echo "adopted '$(VM_NAME)': marked as owned by this harness"

destroy:
	@out="$$($(VIRSH) domstate "$(VM_NAME)" 2>&1)" && rc=0 || rc=$$?; \
	if [ $$rc -ne 0 ]; then \
		case "$$out" in \
			"error: failed to get domain"*) echo "domain '$(VM_NAME)' does not exist; nothing to destroy"; exit 0 ;; \
			*) echo "could not query domain '$(VM_NAME)': $$out" >&2; exit 1 ;; \
		esac; \
	fi; \
	state="$$out"; \
	mark="$$($(VIRSH) metadata "$(VM_NAME)" "$(HARNESS_METADATA_URI)" --config 2>/dev/null || true)"; \
	[ -n "$$mark" ] || { \
		echo "domain '$(VM_NAME)' is not marked as owned by this harness; refusing to destroy it." >&2; \
		echo "if this harness created it before the ownership mark existed, run: make -C vm adopt VM_NAME=$(VM_NAME)" >&2; \
		exit 1; \
	}; \
	if [ "$$state" != "shut off" ]; then \
		$(VIRSH) destroy "$(VM_NAME)"; \
	fi; \
	$(VIRSH) undefine "$(VM_NAME)" --remove-all-storage; \
	rm -f "$(KS)"; \
	echo "destroyed '$(VM_NAME)'"

console:
	$(VIRSH) console "$(VM_NAME)"

require-harness-key:
	@if [ -e "$(HARNESS_KEY)" ] && [ -e "$(HARNESS_PUBKEY)" ]; then \
		:; \
	elif [ -e "$(HARNESS_KEY)" ] || [ -e "$(HARNESS_PUBKEY)" ]; then \
		echo "harness SSH key pair under $(HARNESS_SSH_DIR) is half-present (one of id_ed25519/id_ed25519.pub is missing); remove both and run 'make -C vm create' to regenerate them, or restore the missing file" >&2; \
		exit 1; \
	else \
		echo "no harness SSH key at $(HARNESS_KEY); it is generated once by 'make -C vm create' and must not be regenerated behind the VM's back" >&2; \
		exit 1; \
	fi

ssh: require-harness-key
	@ip="$$($(VIRSH) domifaddr "$(VM_NAME)" --source lease 2>/dev/null | awk '/ipv4/{print $$4}' | cut -d/ -f1)"; \
	[ -n "$$ip" ] || { echo "VM has no IPv4 address yet" >&2; exit 1; }; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip"

screenshot:
	@out="$${OUT:-}"; \
	[ -n "$$out" ] || { echo "OUT is not set; usage: make screenshot OUT=/absolute/path/to.png" >&2; exit 1; }; \
	case "$$out" in \
		/*) ;; \
		*) echo "OUT must be an absolute path ('make -C vm' changes the working directory to vm/, so a relative path would land there rather than where you expect): $$out" >&2; exit 1 ;; \
	esac; \
	state="$$($(VIRSH) domstate "$(VM_NAME)" 2>/dev/null || true)"; \
	[ "$$state" = "running" ] || { echo "VM '$(VM_NAME)' is not running" >&2; exit 1; }; \
	tmp="$$(mktemp --suffix=.ppm)"; \
	trap 'rm -f "$$tmp"' EXIT; \
	$(VIRSH) screenshot "$(VM_NAME)" "$$tmp" >/dev/null; \
	magick "$$tmp" "$$out"; \
	echo "saved screenshot to $$out"

viewer:
	virt-viewer --connect qemu:///system "$(VM_NAME)"

type:
	@[ -n "$${TEXT:-}" ] || { echo "TEXT is not set; usage: make type TEXT='hello world'" >&2; exit 1; }; \
	sequence="$$(bash "$(KEYMAP_SCRIPT)" "$$TEXT")"; \
	while IFS= read -r keys; do \
		$(VIRSH) send-key "$(VM_NAME)" $$keys </dev/null; \
	done <<<"$$sequence"

key:
	@[ -n "$${KEYS:-}" ] || { echo "KEYS is not set; usage: make key KEYS='KEY_LEFTMETA KEY_ENTER'" >&2; exit 1; }; \
	$(VIRSH) send-key "$(VM_NAME)" $$KEYS

test: require-harness-key
	@wait_for_ssh() { \
		local target="$$1"; \
		ssh $(SSH_OPTS) -o ConnectionAttempts=$(SSH_CONNECT_ATTEMPTS) "$$target" true \
			|| { echo "ssh to $$target never became reachable after $(SSH_CONNECT_ATTEMPTS) attempts" >&2; return 1; }; \
	}; \
	ip="$$(bash "$(WAIT_FOR_IP_SCRIPT)" "$(VM_NAME)" $(IP_WAIT_TIMEOUT))" || exit 1; \
	echo "vm ip: $$ip"; \
	wait_for_ssh "$(VM_USER)@$$ip" || exit 1; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'sudo loginctl enable-linger $(VM_USER)'; \
	rsync -a --exclude=.git --exclude=vm/.ssh -e "ssh $(SSH_OPTS)" "$(REPO_ROOT)/" "$(VM_USER)@$$ip:vekrona/"; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'cd vekrona && ./install.sh --skip 10-nvidia'; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'bash vekrona/vm/session-check.sh'; \
	snap_n="$$(ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'sudo /home/$(VM_USER)/.local/bin/vekrona-snapshot vm-test')"; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" "sudo /home/$(VM_USER)/.local/bin/vekrona-rollback --yes $$snap_n"; \
	python3 "$(WAIT_FOR_REBOOT_SCRIPT)" "$(VM_NAME)" $(REBOOT_EVENT_TIMEOUT) $(AGENT_RECONNECT_TIMEOUT); \
	wait_for_ssh "$(VM_USER)@$$ip" || exit 1; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" "sudo bash vekrona/vm/rollback-check.sh $$snap_n"; \
	state="$$(ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'systemctl is-system-running --wait' 2>/dev/null || true)"; \
	if [ "$$state" != "running" ]; then \
		failed="$$(ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'systemctl --failed --no-legend' 2>/dev/null || true)"; \
		echo "system did not reach 'running' after boot: state=$$state" >&2; \
		[ -z "$$failed" ] || { echo "failed units:" >&2; echo "$$failed" >&2; }; \
		exit 1; \
	fi; \
	ssh $(SSH_OPTS) "$(VM_USER)@$$ip" 'bash vekrona/vm/login-manager-check.sh'; \
	echo "vm test passed"
