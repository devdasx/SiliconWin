# Convenience targets for SiliconWin. The scripts in Scripts/ do the real
# work; settings come from Scripts/env.sh and Scripts/local.env.

.DEFAULT_GOAL := help
.PHONY: help app qemu firmware tpm swift lint clean

help: ## Show the available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z]+:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

app: ## Build SiliconWin.app (and the QEMU, firmware and TPM runtime the first time)
	Scripts/build-app.sh

qemu: ## Build QEMU and libslirp
	Scripts/build-qemu.sh

firmware: ## Build the UEFI firmware
	Scripts/build-firmware.sh

tpm: ## Build swtpm, libtpms and json-glib
	Scripts/build-tpm.sh

swift: ## Compile the Swift app only (debug build, quick check)
	cd App && swift build

lint: ## Check the build scripts (bash -n, ShellCheck, Python)
	bash -n Scripts/*.sh
	shellcheck -x Scripts/*.sh
	python3 -m py_compile Scripts/bundle-runtime.py
	rm -rf Scripts/__pycache__

clean: ## Remove Swift build products and dist/ (keeps the runtime build area)
	rm -rf App/.build dist
