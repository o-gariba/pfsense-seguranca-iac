# Diretivas Permanentes para Agentes (`AGENTS.md`)

Este documento consolida as regras arquiteturais, restrições invioláveis e guardrails operacionais do projeto **`pfsense-kvm-iac`**. Todo agente automatizado (Antigravity CLI ou equivalente) deve obedecer integralmente a estas diretrizes antes de propor ou aplicar alterações.

---

## 1. Contexto do Ambiente e Restrições Absolutas

### Ambiente Alvo Validado (Host)

* **SO do Host:** Ubuntu 26.04 LTS (`x86_64`), CPU com suporte a virtualização assistida por hardware (VT-x / AMD-V e IOMMU ativos).
* **Stack de Virtualização:** KVM + QEMU + `libvirt` acessível sem `sudo` via `qemu:///system` (usuário membro dos grupos `libvirt` e `kvm`).
* **Recursos Pré-existentes no Host (NÃO DESTRUIR NEM MODIFICAR):**
  * Rede NAT `default` (`virbr0`, `192.168.122.0/24`, DHCP ativo) — consumida **somente** como referência externa de **WAN**.
  * Storage Pool `default` (`/var/lib/libvirt/images`) — preservado intacto; os artefatos do laboratório devem residir em pool dedicado (`pfsense-lab-pool`).

### Hard Constraints (Invioláveis)

1. **100% Open Source / Community Edition:** Utilizar exclusivamente **pfSense CE 2.9.x** (baseado em FreeBSD 16.0-CURRENT) e pacotes comunitários abertos (`System_Patches`, `pfBlockerNG`, `HAProxy`, `WireGuard`, `Suricata` com *ET Open*). É estritamente proibido depender de recursos exclusivos do pfSense Plus ou licenças proprietárias.
2. **Replicabilidade Pública (GitHub/GitLab):** Nenhuma dependência de caminhos absolutos de usuário específico no host, nenhum IP fixo *hardcoded* fora de variáveis parametrizadas e nenhuma imagem `.iso`, `.img` ou `.qcow2` commitada no Git.
3. **Zero Segredos no Repositório:** Chaves SSH, chaves WireGuard, certificados CA/TLS e hashes de senha devem ser gerados localmente em tempo de execução no diretório `secrets/` (ignorado pelo `.gitignore`) e validados continuamente por `gitleaks`.
4. **Editor Padrão:** Sempre que scripts, `Makefile`, comentários ou documentação sugerirem edição manual de arquivos em terminal, utilizar exclusivamente **`vim`** (nunca `nano`).
5. **Isolamento de Estado:** O alvo `make destroy` deve remover **apenas** os recursos criados pelo projeto (prefixo `pfsense-lab-*`), preservando intactos a rede `default`, o pool `default` e demais arquivos do host.

---

## 2. Stack Tecnológica e Regra Crítica de Schema

| Camada | Tecnologia | Versão Alvo | Responsabilidade |
| --- | --- | --- | --- |
| **Provisionamento IaC** | OpenTofu (`tofu`) | `>= 1.8` | Ciclo de vida declarativo de redes, volumes e VMs |
| **Provider Hipervisor** | `dmacvicar/libvirt` | `~> 0.9.9` | Interface direta com `qemu:///system` |
| **Bootstrap Linux** | Cloud Images + `cloud-init` (`xorriso`/`cloud-localds`) | Ubuntu 24.04/26.04 ou Debian 12/13 | Provisionamento zero-touch de `pfsense-lab-lan-client` e `pfsense-lab-dmz-srv` |
| **Bootstrap Firewall** | pfSense CE + ECL (`config.xml.tmpl`) | `2.9.2` | Injeção declarativa de interfaces, firewall, Kea DHCP e hardening |
| **Gerência de Configuração** | `ansible-core` | `>= 2.17` | Deploy de Nginx/API na DMZ, tooling na LAN e orquestração |
| **Testes de Aceitação** | `bats-core` (ou `pytest`) + `curl`/`nc`/`dig`/`nmap` | Atual | Verificação automatizada de matriz de conectividade e bloqueios |
| **Orquestração Local** | GNU `make` + Bash (`set -euo pipefail`) | Atual | Interface unificada (`doctor`, `init`, `up`, `provision`, `test`, `lint`, `destroy`) |
| **Qualidade & Segurança** | `tflint`, `checkov`, `shellcheck`, `ansible-lint`, `gitleaks` | Atual | Validação estática local (`pre-commit`) e em CI |

### Diretiva Obrigatória — Schema-First para `dmacvicar/libvirt` `v0.9.x`

A série `v0.9.x` do provider `dmacvicar/libvirt` substituiu o schema manual das versões `v0.7`/`v0.8` por um **schema gerado automaticamente a partir do esquema XML do libvirt**, introduzindo mudanças estruturais incompatíveis com exemplos legados.

* **NÃO escreva blocos HCL** de `libvirt_domain`, `libvirt_network`, `libvirt_pool` ou `libvirt_volume` confiando em exemplos de memória da era `0.7`/`0.8`.
* Antes de codificar qualquer módulo em `tofu/modules/`, execute `tofu init` em um bloco mínimo com o provider pinado (`version = "~> 0.9.9"`) e inspecione o schema real via:

```bash
tofu providers schema -json | jq '.provider_schemas["registry.opentofu.org/dmacvicar/libvirt"].resource_schemas | keys'
```

* Consulte os atributos exatos de cada recurso no JSON retornado (incluindo blocos `create`/`destroy` de `libvirt_pool` e `destroy.shutdown.timeout` de `libvirt_domain` introduzidos na série `0.9.x`) antes de gerar os arquivos `.tf`.

---

## 3. Guardrails Operacionais

* **Execução Sequencial por Marcos:** Executar um marco de `SPEC.md` por vez, validando integralmente o respectivo *Gate de Verificação* antes de avançar.
* **Confirmação Explícita:** Solicitar aprovação humana explícita antes de executar qualquer comando com `sudo`, `tofu destroy`, `virsh undefine`, `virsh net-destroy` ou modificação em `/etc/libvirt/` e `/var/lib/libvirt/`.
* **Sem "Hacks" de Segurança:** Nunca aplicar ou sugerir `chmod 777`, desabilitar AppArmor, usar `StrictHostKeyChecking=no` de forma permanente fora de escopo efêmero isolado do laboratório ou embutir credenciais em texto claro em arquivos rastreados pelo Git.
* **Detecção de Drift e Falhas:** Se `tofu apply` falhar por permissão de arquivo em `/var/lib/libvirt/images`, diagnosticar via `ls -ld` e `dmesg | grep -i apparmor` antes de propor qualquer alteração de política.
* **Padrão de Commits:** Utilizar *Conventional Commits* (`feat(tofu):`, `fix(pfsense):`, `test(firewall):`, `docs(adr):`, `chore(repo):`), mantendo cada marco em commits atômicos e revisáveis.
