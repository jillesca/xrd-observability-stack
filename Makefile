CONTAINER_ENGINE := $(shell command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE          := $(shell command -v docker-compose >/dev/null 2>&1 && echo docker-compose || echo $(CONTAINER_ENGINE) compose)
COMPOSE_VM       := $(COMPOSE) -f compose.yaml -f compose.override.vm.yaml

# Remote VM deployment (split mode: Alloy+Loki on VM, rest on laptop)
VM_HOST  ?= 10.10.20.15
VM_USER  ?= developer
VM_PATH  ?= /home/developer/gnp-syslog
VM_SSH   := ssh $(VM_USER)@$(VM_HOST)
VM_COMPOSE := docker compose -f $(VM_PATH)/vm/compose.yaml

.PHONY: help up up-vm down down-vm restart restart-vm \
        restart-grafana logs ps validate \
        vm-sync vm-start vm-stop vm-deploy vm-logs vm-status

help:
	@echo "Usage:"
	@echo ""
	@echo "Full-VM mode (everything on the VM — primary)"
	@echo "  make up-vm           Start full stack + Alloy syslog + macvlan networking"
	@echo "  make down-vm         Stop full-VM stack"
	@echo "  make restart-vm      Restart full-VM stack"
	@echo ""
	@echo "Split mode (Alloy+Loki on VM, Grafana+Prometheus on laptop)"
	@echo "  make vm-deploy       Rsync config + start Alloy/Loki on VM"
	@echo "  make up              Start laptop stack (set LOKI_URL=http://VM_HOST:3100)"
	@echo "  make down            Stop laptop stack"
	@echo "  make restart         Restart laptop stack"
	@echo ""
	@echo "VM management"
	@echo "  make vm-sync         Rsync Alloy/Loki config files to VM"
	@echo "  make vm-start        Start Alloy+Loki on VM via SSH"
	@echo "  make vm-stop         Stop Alloy+Loki on VM via SSH"
	@echo "  make vm-logs         Follow VM syslog stack logs via SSH"
	@echo "  make vm-status       Show running containers on VM via SSH"
	@echo ""
	@echo "Utility"
	@echo "  make restart-grafana Restart only the Grafana container (picks up dashboard changes)"
	@echo "  make logs            Follow logs"
	@echo "  make ps              Show running containers"
	@echo "  make validate        Check Prometheus targets"
	@echo ""
	@echo "Container engine detected: $(CONTAINER_ENGINE)"
	@echo "Env vars:"
	@echo "  VM_HOST    Remote VM IP/hostname (default: $(VM_HOST))"
	@echo "  VM_USER    SSH user on VM        (default: $(VM_USER))"
	@echo "  VM_PATH    Remote working dir    (default: $(VM_PATH))"
	@echo "  LOKI_URL   Loki URL for Grafana  (default: http://10.10.20.15:3100)"
	@echo "  SYSLOG_DESTINATION  XRd syslog target IP (default: 10.10.20.11)"

up:
	$(COMPOSE) up -d

up-vm:
	$(COMPOSE_VM) up -d

down:
	$(COMPOSE) down

down-vm:
	$(COMPOSE_VM) down

restart: down up

restart-grafana:
	$(COMPOSE) restart grafana

restart-vm: down-vm up-vm

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

validate:
	@echo "Container engine: $(CONTAINER_ENGINE)"
	@echo "Checking Prometheus targets..."
	@curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'

# ── Remote VM targets ────────────────────────────────────────────────────────

vm-sync:
	@echo "Syncing config files to $(VM_USER)@$(VM_HOST):$(VM_PATH) ..."
	$(VM_SSH) "mkdir -p $(VM_PATH)/alloy $(VM_PATH)/loki $(VM_PATH)/vm"
	rsync -avz alloy/config.alloy   $(VM_USER)@$(VM_HOST):$(VM_PATH)/alloy/
	rsync -avz loki/loki-config.yaml $(VM_USER)@$(VM_HOST):$(VM_PATH)/loki/
	rsync -avz vm/                  $(VM_USER)@$(VM_HOST):$(VM_PATH)/vm/

vm-start:
	@echo "Starting Alloy+Loki on $(VM_HOST) ..."
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) up -d"

vm-stop:
	@echo "Stopping Alloy+Loki on $(VM_HOST) ..."
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) down"

vm-deploy: vm-sync vm-start

vm-logs:
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) logs -f"

vm-status:
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) ps"
