# Especificação Técnica de Projeto IaC — `pfsense-kvm-iac`

> **Diretiva para o Agente (Antigravity CLI):** Trate este documento como a especificação canônica de arquitetura, requisitos não funcionais e plano de execução. Execute os marcos em ordem sequencial, valide cada critério de aceitação (*gate*) antes de avançar e utilize subagentes paralelos apenas para tarefas independentes (ex.: documentação/ADRs em paralelo com linters de CI).

## 1. Contexto do Ambiente e Restrições Absolutas

### Ambiente Alvo Validado (Host)

* **SO do Host:** Ubuntu 26.04 LTS (`x86_64`), CPU Intel Core i7-9750H (VT-x e VT-d/IOMMU ativos).
* **Stack de Virtualização:** KVM + QEMU `10.2.1` + `libvirt 12.0.0` acessível sem `sudo` via `qemu:///system` (usuário membro dos grupos `libvirt` e `kvm`).
* **Recursos Pré-existentes no Host (NÃO DESTRUIR):**
* Rede NAT `default` (`virbr0`, `192.168.122.0/24`, DHCP ativo) — será consumida somente como referência externa de **WAN**.
* Storage Pool `default` (`/var/lib/libvirt/images`, `ext4` em NVMe, ~273 GiB utilizáveis fora da reserva `root`).



### Hard Constraints (Invioláveis)

1. **100% Open Source / Community Edition:** Utilizar exclusivamente **pfSense CE 2.9.x** (atual `2.9.2`, baseado em FreeBSD 16.0-CURRENT) e pacotes comunitários abertos (`System_Patches`, `pfBlockerNG`, `HAProxy`, `WireGuard`, `Suricata` com *ET Open*). Proibido depender de recursos exclusivos do pfSense Plus ou licenças proprietárias.
2. **Replicabilidade Pública (GitHub/GitLab):** Nenhuma dependência de caminhos absolutos do usuário atual (ex.: `/home/pedro-...`), nenhum IP fixo *hardcoded* fora de variáveis e nenhuma imagem `.iso` ou `.qcow2` commitada no Git.
3. **Zero Segredos no Repositório:** Chaves SSH, chaves WireGuard, certificados CA/TLS e hashes de senha devem ser gerados localmente em tempo de execução (diretório `secrets/` ignorado pelo `.gitignore`) e validados por `gitleaks`.
4. **Editor Padrão:** Sempre que scripts, `Makefile` ou documentação sugerirem edição manual de arquivos em terminal, utilizar **`vim`** (nunca `nano`).
5. **Isolamento de Estado:** O comando `make destroy` deve remover apenas os recursos criados pelo projeto (prefixo `pfsense-lab-*`), preservando intactos a rede `default` e outros arquivos do host.

---

## 2. Stack Tecnológica e Regra Crítica de Schema

| Camada | Tecnologia | Versão Alvo | Responsabilidade |
| --- | --- | --- | --- |
| **Provisionamento IaC** | OpenTofu (`tofu`) | `≥ 1.8` | Ciclo de vida declarativo de redes, volumes e VMs |
| **Provider Hipervisor** | `dmacvicar/libvirt` | `~> 0.9.9` | Interface direta com `qemu:///system` |
| **Bootstrap Linux** | Cloud Images + `cloud-init` (`xorriso`/`cloud-localds`) | Ubuntu 24.04/26.04 ou Debian 12/13 | Provisionamento zero-touch de `vm-lan-client` e `vm-dmz-srv` |
| **Bootstrap Firewall** | pfSense CE + ECL (`config.xml.tmpl`) | `2.9.2` | Injeção declarativa de interfaces, firewall, Kea DHCP e hardening |
| **Gerência de Configuração** | `ansible-core` | `≥ 2.17` | Deploy de Nginx/API na DMZ, tooling na LAN e orquestração |
| **Testes de Aceitação** | `bats-core` (ou `pytest`) + `curl`/`nc`/`dig`/`nmap` | Atual | Verificação automatizada de matriz de conectividade e bloqueios |
| **Orquestração Local** | GNU `make` + Bash (`set -euo pipefail`) | Atual | Interface unificada (`doctor`, `up`, `provision`, `test`, `destroy`) |
| **Qualidade & Segurança** | `tflint`, `checkov`, `shellcheck`, `ansible-lint`, `gitleaks` | Atual | Validação estática local (`pre-commit`) e em CI |

### Diretiva Obrigatória — Schema-First para `dmacvicar/libvirt` `v0.9.x`

A série `v0.9.x` do provider `dmacvicar/libvirt` substituiu o schema manual das versões `v0.7`/`v0.8` por um **schema gerado automaticamente a partir do esquema XML do libvirt**, introduzindo mudanças estruturais incompatíveis com exemplos legados.

**Regra para o Agente:**

* **NÃO escreva blocos HCL** de `libvirt_domain`, `libvirt_network`, `libvirt_pool` ou `libvirt_volume` confiando em exemplos de memória da era `0.7`/`0.8`.
* Antes de codificar qualquer módulo em `tofu/modules/`, execute `tofu init` em um bloco mínimo com o provider pinado (`version = "~> 0.9.9"`) e inspecione o schema real via:

```bash
tofu providers schema -json | jq '.provider_schemas["registry.opentofu.org/dmacvicar/libvirt"].resource_schemas | keys'

```

* Consulte os atributos exatos de cada recurso no JSON retornado (incluindo blocos `create`/`destroy` de `libvirt_pool` e `destroy.shutdown.timeout` de `libvirt_domain` introduzidos na série `0.9.x`) antes de gerar os arquivos `.tf`.

---

## 3. Arquitetura de Topologia e Estrutura do Repositório

### Topologia de 3 Zonas

| Zona | Nome no `libvirt` | Sub-rede CIDR | Gateway | Modo no `libvirt` | DHCP / DNS |
| --- | --- | --- | --- | --- | --- |
| **WAN** | `default` *(existente)* | `192.168.122.0/24` | `192.168.122.1` | NAT (`virbr0`) | `dnsmasq` do host |
| **LAN** | `pfsense-lab-lan` | `10.10.10.0/24` | `10.10.10.1` | Isolada (sem `forward`, sem `dhcp`) | pfSense (`Kea DHCP` + `Unbound`) |
| **DMZ** | `pfsense-lab-dmz` | `10.10.20.0/24` | `10.10.20.1` | Isolada (sem `forward`, sem `dhcp`) | pfSense (`Kea DHCP` estático) |

### Especificação das VMs

| VM | vCPU | RAM | Disco (`.qcow2`) | NICs VirtIO (ordem estrita) | Requisitos de Hardware Virtual |
| --- | --- | --- | --- | --- | --- |
| `pfsense-lab-fw` | 2 | 2048 MiB *(4096 MiB c/ Suricata)* | 20 GiB | `vtnet0`: `default`, `vtnet1`: `pfsense-lab-lan`, `vtnet2`: `pfsense-lab-dmz` | CPU `host-passthrough` (AES-NI), disco VirtIO, console serial `pty` + VNC/SPICE |
| `pfsense-lab-lan-client` | 2 | 2048 MiB | 15 GiB | `eth0`: `pfsense-lab-lan` | Cloud Image + `cloud-init`, MAC determinístico |
| `pfsense-lab-dmz-srv` | 1 | 1024 MiB | 10 GiB | `eth0`: `pfsense-lab-dmz` | Cloud Image + `cloud-init`, MAC fixo (`52:54:00:20:00:10`) para reserva `10.10.20.10` |

### Estrutura Alvo de Diretórios

```text
pfsense-kvm-iac/
├── AGENTS.md                        # Regras permanentes para o Antigravity CLI neste repo
├── README.md                        # Visão geral, diagrama Mermaid, pré-requisitos e quickstart
├── LICENSE                          # MIT ou Apache-2.0
├── Makefile                         # Entrypoint padronizado (doctor, init, up, provision, test, lint, destroy)
├── .gitignore                       # Ignora isos/, secrets/, .env, *.tfstate*, *.qcow2, .terraform/
├── .pre-commit-config.yaml          # gitleaks, tofu fmt/validate, tflint, shellcheck, ansible-lint
├── .github/workflows/ci.yml         # Pipeline de lint, security scan e validação de templates XML/HCL
├── docs/
│   ├── architecture.md              # Matriz de tráfego, fluxos e diagramas
│   └── adr/
│       ├── 001-opentofu-libvirt-09.md
│       ├── 002-pfsense-ce-zfs-and-vtnet-offload.md
│       └── 003-ecl-config-templating.md
├── tofu/
│   ├── versions.tf                  # Pin OpenTofu + dmacvicar/libvirt (~> 0.9.9)
│   ├── providers.tf                 # uri = var.libvirt_uri (default: qemu:///system)
│   ├── variables.tf                 # Parâmetros configuráveis (RAM, vCPU, CIDRs, pool, caminhos)
│   ├── terraform.tfvars.example     # Exemplo pronto para copiar e editar com vim
│   ├── main.tf                      # Composição dos módulos
│   ├── outputs.tf                   # IPs, MACs, UUIDs e inventário JSON para o Ansible
│   └── modules/
│       ├── network/                 # Cria pfsense-lab-lan e pfsense-lab-dmz (isoladas)
│       ├── storage/                 # Pool dedicado pfsense-lab-pool + volumes base/overlay
│       ├── pfsense/                 # Domínio pfsense-lab-fw + anexação ISO + disco ECL
│       └── linux-node/              # Domínios Linux genéricos com cloud-init NoCloud ISO
├── pfsense/
│   ├── config.xml.tmpl              # Template sanitizado com variáveis ${VAR} (sem segredos reais)
│   └── README.md                    # Instruções de obtenção da ISO Netgate Installer + verificação SHA256
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/                   # Inventário dinâmico gerado a partir de `tofu output -json`
│   ├── playbooks/
│   │   ├── site.yml                 # Configura DMZ e LAN
│   │   └── verify.yml               # Executa matriz de testes ponta a ponta
│   └── roles/
│       ├── dmz_web/                 # Nginx + endpoint /health + cabeçalhos de diagnóstico
│       └── lan_client/              # Ferramentas (curl, dig, nmap, tcpdump, wireguard-tools, vim)
├── scripts/
│   ├── doctor.sh                    # Verifica KVM, grupos, virt-host-validate, binários e SHA256 da ISO
│   ├── gen-secrets.sh               # Gera chaves SSH ed25519, chaves WireGuard, CA local e bcrypt hash em secrets/
│   └── build-ecl-image.sh           # Renderiza config.xml.tmpl via envsubst e empacota imagem FAT32/ISO (config/config.xml)
└── tests/
    └── firewall_matrix.bats         # Suíte de testes de aceitação de rede e segurança

```

---

## 4. Especificações Detalhadas dos Componentes

### 4.1. Módulo `storage` e Isolamento de Permissões

* Criar um pool dedicado `pfsense-lab-pool` apontando para `/var/lib/libvirt/images/pfsense-lab` (criado via `scripts/doctor.sh` ou recurso `libvirt_pool` com permissão `0711` compatível com `libvirt-qemu` e AppArmor do Ubuntu, **sem desabilitar AppArmor**).
* Utilizar *backing volumes* (Cloud Images oficiais em modo somente leitura) + volumes overlay em `.qcow2` para criação das VMs Linux em segundos.

### 4.2. Template `pfsense/config.xml.tmpl` (Hardening de Mercado)

O template renderizado por `scripts/build-ecl-image.sh` e injetado via **External Configuration Locator (ECL)** deve garantir, desde o primeiro boot:

* **Ajuste obrigatório KVM + FreeBSD (`vtnet`):** Ativar `disablechecksumoffloading`, `disablesegmentationoffloading` e `disablelargereceiveoffloading` na seção `system`.
* **Interfaces e Endereçamento:**
* `wan` (`vtnet0`): DHCP (`192.168.122.0/24`); opção `blockpriv` **desativada** por variável (`var.lab_allow_rfc1918_wan = true`) para permitir testes de DNAT e WireGuard a partir do host Ubuntu, com aviso documentado para ativar em produção.
* `lan` (`vtnet1`): Estático `10.10.10.1/24`.
* `opt1` (`vtnet2`, descrição `DMZ`): Estático `10.10.20.1/24`.


* **Serviços Base:**
* **Kea DHCP** ativo na LAN (`10.10.10.100–10.10.10.200`) e reserva estática na DMZ (`10.10.20.10` vinculada ao MAC de `pfsense-lab-dmz-srv`).
* **Unbound DNS Resolver** com DNSSEC ativo e *Host Override* `app.lab.local` apontando para `10.10.20.10`.


* **Hardening de Acesso:**
* Conta `admin` **desabilitada**; usuário administrativo nominal (`${PFSENSE_ADMIN_USER}`) criado com hash bcrypt gerado em `secrets/` e chave pública SSH injetada em `authorizedkeys`.
* WebGUI estritamente em **HTTPS** com certificado gerado pela CA local em `secrets/`, sem qualquer regra de entrada para WebGUI ou SSH na `WAN` ou `DMZ`.
* SSH habilitado apenas com autenticação por chave pública (`sshdkeyonly`).


* **Política de Firewall (*Default Deny*):**
* **Aliases:** `RFC1918` (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) e `WEB_PORTS` (`80`, `443`).
* **DMZ:** Regra explícita **BLOCK + LOG** com origem `DMZ net` e destino `RFC1918` (impede movimento lateral para a LAN e para a rede do host); regra **PASS** mínima apenas para DNS (`10.10.20.1:53`) e atualizações HTTP/HTTPS de saída.
* **LAN:** Regra **PASS** controlada para `DMZ` (`WEB_PORTS` + SSH administrativo) e saída controlada para Internet (`WAN`).
* **NAT (DNAT / Port Forward):** Regra na `WAN` encaminhando porta `8443` (ou `443`) para `10.10.20.10:80/443` com regra de firewall associada.



### 4.3. Matriz de Testes Automatizados (`tests/firewall_matrix.bats`)

A suíte de aceitação deve executar comandos reais via SSH (usando a chave efêmera em `secrets/` com `ProxyJump` pela LAN quando necessário) e validar código de saída determinístico:

| Caso de Teste | Origem → Destino | Protocolo / Porta | Resultado Esperado |
| --- | --- | --- | --- |
| `T01_dmz_lateral_block` | `vm-dmz-srv` → `vm-lan-client` | ICMP / TCP 22 | **BLOCK** (timeout/recusado + entrada no log do firewall) |
| `T02_lan_to_dmz_web` | `vm-lan-client` → `10.10.20.10` | HTTP 80 (`/health`) | **PASS** (HTTP `200 OK`) |
| `T03_lan_to_wan_egress` | `vm-lan-client` → Internet | HTTPS 443 | **PASS** (prova `vtnet` sem erro de checksum) |
| `T04_unbound_override` | `vm-lan-client` → `10.10.10.1` | DNS 53 (`app.lab.local`) | **PASS** (resolve exatamente `10.10.20.10`) |
| `T05_wan_dnat_to_dmz` | Host Ubuntu → IP WAN pfSense | TCP 8443/443 | **PASS** (HTTP `200 OK` servido pelo Nginx da DMZ) |
| `T06_wan_mgmt_closed` | Host Ubuntu → IP WAN pfSense | TCP 443 (WebGUI) / TCP 22 | **BLOCK** (gerência inacessível pela WAN) |
| `T07_wireguard_tunnel` *(opcional/fase 2)* | Host Ubuntu (`wg0`) → `10.10.10.1` | UDP 51820 + ICMP interno | **PASS** (handshake recente e roteamento à LAN) |

---

## 5. Plano de Execução em Marcos para o Antigravity CLI

Execute rigorosamente um marco por vez. Não avance se o **Gate de Verificação** falhar.

### Marco 0 — Bootstrap do Repositório, Governança e Diagnóstico

* **Ações:**
1. Inicializar repositório Git (`git init -b main`), criar `.gitignore`, `LICENSE`, `AGENTS.md` (copiando as restrições das seções 1, 2 e 6) e `.pre-commit-config.yaml`.
2. Implementar `scripts/doctor.sh` (verifica `/dev/kvm`, grupos `libvirt`/`kvm`, `virt-host-validate qemu`, presença de `tofu`, `ansible`, `virsh`, `xorriso`, `jq`, `envsubst`, espaço livre em `/var/lib/libvirt/images` e checksum SHA256 da ISO do pfSense CE caso presente em `isos/`).
3. Criar `Makefile` esqueleto com o alvo `make doctor` e `make lint`.


* **Gate de Verificação:** `make doctor` e `shellcheck scripts/*.sh` retornam código de saída `0`; `git status` não mostra arquivos temporários nem sensíveis.

### Marco 1 — Descoberta de Schema e Módulos Core (`network` e `storage`)

* **Ações:**
1. Criar `tofu/versions.tf` e `tofu/providers.tf` pinando `dmacvicar/libvirt` em `~> 0.9.9` e executar `tofu init`.
2. Inspecionar `tofu providers schema -json` e documentar no ADR `docs/adr/001-opentofu-libvirt-09.md` a estrutura exata dos recursos da série `0.9.x`.
3. Implementar `tofu/modules/network` (`pfsense-lab-lan` e `pfsense-lab-dmz`) e `tofu/modules/storage` (`pfsense-lab-pool` + base image Linux).
4. Criar `tofu/variables.tf` e `tofu/terraform.tfvars.example`.


* **Gate de Verificação:** `tofu fmt -check -recursive`, `tofu validate`, `tflint` e `tofu apply` criando apenas redes e pool; confirmar via `virsh -c qemu:///system net-list --all` e `pool-list --all` que `pfsense-lab-lan`, `pfsense-lab-dmz` e `pfsense-lab-pool` estão ativos sem alterar `default`.

### Marco 2 — Módulo `linux-node` e Provisionamento via `cloud-init`

* **Ações:**
1. Implementar `scripts/gen-secrets.sh` gerando chave SSH `ed25519` efêmera em `secrets/lab_ed25519` (permissão `0600`).
2. Implementar `tofu/modules/linux-node` gerando ISOs `NoCloud` (`user-data` + `meta-data` + `network-config`) e instanciando `pfsense-lab-lan-client` e `pfsense-lab-dmz-srv`.
3. Configurar `tofu/outputs.tf` exportando metadados estruturados (MACs, nomes de domínio, UUIDs) consumíveis por Ansible e scripts.


* **Gate de Verificação:** `tofu plan` e `tofu apply` sobem ambas as VMs Linux sem erros; `virsh -c qemu:///system list --all` mostra os dois domínios em execução e conectados respectivamente às bridges `pfsense-lab-lan` e `pfsense-lab-dmz`.

### Marco 3 — Módulo `pfsense`, Template ECL e Hardening Base

* **Ações:**
1. Criar `pfsense/config.xml.tmpl` com o hardening completo da Seção 4.2 (incluindo desativação de *hardware checksum offload*, Kea DHCP, Unbound, Aliases, bloqueio `DMZ → LAN` e DNAT) e validar bem-formação com `xmllint --noout`.
2. Implementar `scripts/build-ecl-image.sh` (gera imagem FAT32/ISO contendo `config/config.xml` renderizado com os valores de `secrets/`).
3. Implementar `tofu/modules/pfsense` anexando as 3 NICs VirtIO na ordem exata (`WAN`, `LAN`, `DMZ`), CPU `host-passthrough`, disco `.qcow2` de 20 GiB, ISO do pfSense CE (`2.9.x`) e volume ECL.
4. Escrever `docs/adr/002-pfsense-ce-zfs-and-vtnet-offload.md` e `docs/adr/003-ecl-config-templating.md`.


* **Gate de Verificação:** Após a instalação inicial em **Auto (ZFS)** e reboot com o volume ECL, `pfsense-lab-fw` obtém IP na WAN (`192.168.122.x`), `pfsense-lab-lan-client` recebe IP via Kea DHCP em `10.10.10.100–200`, `pfsense-lab-dmz-srv` recebe `10.10.20.10`, e o acesso SSH via chave à LAN responde para o usuário nominal (com `admin` bloqueado).

### Marco 4 — Configuração de Workloads (Ansible) e Testes Automatizados

* **Ações:**
1. Criar script/plugin de inventário dinâmico lendo `tofu output -json` e configurando `ProxyJump` quando necessário.
2. Implementar roles Ansible `dmz_web` (Nginx + `/health`) e `lan_client` (ferramentas de diagnóstico + `vim`).
3. Implementar `tests/firewall_matrix.bats` cobrindo `T01` a `T06` (e esqueleto modular para `T07` WireGuard + instalação opcional de `pfBlockerNG`, `HAProxy` e `Suricata`).
4. Integrar `make provision` e `make test` no `Makefile`.


* **Gate de Verificação:** `ansible-lint`, `make provision` (idempotente em segunda execução: `changed=0`) e `make test` com 100% dos testes passando (`T01`–`T06`).

### Marco 5 — CI/CD, Documentação Replicável e Teste de Destruição Limpa

* **Ações:**
1. Criar `.github/workflows/ci.yml` executando em runners sem KVM: `gitleaks`, `shellcheck`, `xmllint`, `tofu fmt -check`, `tofu validate`, `tflint`, `checkov` e `ansible-lint`.
2. Redigir `README.md` completo com diagrama Mermaid da topologia, pré-requisitos, passo a passo de download da ISO CE (sem links expirados), edição do `terraform.tfvars` com `vim`, comandos `make` e guia de troubleshooting.
3. Executar teste de reprodutibilidade ponta a ponta: `make destroy`, confirmar limpeza total dos recursos `pfsense-lab-*` (preservando `default`), seguido de novo `make up && make provision && make test`.


* **Gate de Verificação:** `make lint` e pipeline de CI verdes; `make destroy` limpa 100% dos recursos do lab sem deixar órfãos no `libvirt` nem alterar recursos pré-existentes do host.

---

## 6. Guardrails Operacionais para o Antigravity CLI

* **Confirmação Explícita:** Solicitar aprovação humana (`ctrl+k` no Antigravity CLI) antes de executar qualquer comando com `sudo`, `tofu destroy`, `virsh undefine`, `virsh net-destroy` ou modificação em `/etc/libvirt/` e `/var/lib/libvirt/`.
* **Sem "Hacks" de Segurança:** Nunca sugerir `chmod 777`, desabilitar AppArmor, usar `StrictHostKeyChecking=no` de forma permanente fora de escopo efêmero do lab ou embutir senhas em texto claro em arquivos rastreados pelo Git.
* **Detecção de Drift e Falhas:** Se `tofu apply` falhar por permissão de arquivo em `/var/lib/libvirt/images`, diagnosticar via `ls -ld` e `dmesg | grep -i apparmor` antes de alterar qualquer política.
* **Padrão de Commits:** Utilizar *Conventional Commits* (`feat(tofu):`, `fix(pfsense):`, `test(firewall):`, `docs(adr):`) mantendo cada marco em commits atômicos e revisáveis.
