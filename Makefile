# AgentOS VM Image Builder
# Usage:
#   make build          - Build the Lite edition (default)
#   make build-server   - Build the Server edition
#   make validate       - Run validation checks on the build scripts
#   make clean          - Remove build artifacts

SHELL := /bin/bash
BUILD_DIR ?= /tmp/agentos-build
OUTPUT_DIR ?= $(BUILD_DIR)/output

.PHONY: build build-lite build-server validate clean help test test-shell test-clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: build-lite ## Build the default (Lite) edition

build-lite: validate ## Build the Lite edition with GNOME desktop
	@echo "Building AgentOS Lite..."
	chmod +x scripts/*.sh
	sudo BUILD_DIR=$(BUILD_DIR) ./scripts/build-vm.sh --lite

build-server: validate ## Build the Server edition (headless)
	@echo "Building AgentOS Server..."
	chmod +x scripts/*.sh
	sudo BUILD_DIR=$(BUILD_DIR) ./scripts/build-vm.sh --server

validate: ## Run validation checks on build scripts and config
	@echo "Running validation checks..."
	@./scripts/validate.sh

clean: ## Remove build artifacts from BUILD_DIR
	@echo "Cleaning build artifacts..."
	@if [ -d "$(BUILD_DIR)" ]; then \
		echo "Removing $(BUILD_DIR)..."; \
		sudo rm -rf "$(BUILD_DIR)"; \
	fi
	@echo "Clean complete."

test: ## Test build in Docker (no Ubuntu host required)
	@./scripts/test-docker.sh

test-full: ## Test build in Docker including desktop (slow)
	@./scripts/test-docker.sh --with-desktop

test-shell: ## Test build then drop into container shell for inspection
	@./scripts/test-docker.sh --shell

test-clean: ## Remove test containers and images
	@./scripts/test-docker.sh --clean

list-output: ## List built artifacts
	@if [ -d "$(OUTPUT_DIR)" ]; then \
		ls -lh $(OUTPUT_DIR)/; \
	else \
		echo "No build output found. Run 'make build' first."; \
	fi
