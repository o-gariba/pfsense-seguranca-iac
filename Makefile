# ==============================================================================
# pfsense-kvm-iac — Makefile
# Orquestração unificada do laboratório (editor padrão: vim)
# ==============================================================================
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

EDITOR ?= vim
LIBVIRT_URI ?= qemu:///system
TOFU_DIR := tofu
ANSIBLE_DIR := ansible

.PHONY: help doctor lint init up provision test destroy

help: ## Exibe os alvos disponíveis no projeto
	@printf "Uso: make <alvo> (editor padrão configurado: %s)\n\n" "$(EDITOR)"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Valida KVM, permissões libvirt, binários obrigatórios, disco e ISO SHA256
	@LIBVIRT_URI="$(LIBVIRT_URI)" ./scripts/doctor.sh

lint: ## Executa análise estática e linters disponíveis nos artefatos do repositório
	@printf "==> Validando scripts Bash com shellcheck...\n"
	@shellcheck -x scripts/*.sh
	@if compgen -G "$(TOFU_DIR)/*.tf" >/dev/null; then \
		printf "==> Validando formatação HCL com OpenTofu...\n"; \
		tofu -chdir="$(TOFU_DIR)" fmt -check -recursive; \
	fi
	@if compgen -G "pfsense/*.xml*" >/dev/null && command -v xmllint >/dev/null 2>&1; then \
		for f in pfsense/*.xml*; do \
			printf "==> Validando XML em %s...\n" "$$f"; \
			xmllint --noout "$$f"; \
		done; \
	fi
	@if command -v gitleaks >/dev/null 2>&1; then \
		printf "==> Verificando ausência de segredos com gitleaks...\n"; \
		gitleaks detect --source . --no-banner; \
	fi
	@printf "==> Lint concluído com sucesso.\n"

init: ## [Marco 1+] Inicializa providers OpenTofu e segredos locais
	@printf "Alvo 'init' será implementado nos Marcos 1 e 2 (edite variáveis futuras com '%s').\n" "$(EDITOR)"

up: ## [Marco 1-3] Provisiona redes, storage pool e máquinas virtuais via OpenTofu
	@printf "Alvo 'up' será implementado nos Marcos 1 a 3.\n"

provision: ## [Marco 4] Aplica playbooks Ansible nas workloads LAN e DMZ
	@printf "Alvo 'provision' será implementado no Marco 4.\n"

test: ## [Marco 4] Executa a matriz automatizada de testes de firewall (BATS)
	@printf "Alvo 'test' será implementado no Marco 4.\n"

destroy: ## [Marco 1+] Remove exclusivamente os recursos pfsense-lab-* preservando 'default'
	@printf "Alvo 'destroy' será implementado a partir do Marco 1.\n"
