.PHONY: up down scan tailscale status access-info help validate-kustomize sync flux-status flux-diff

up:
	./setup.sh

down:
	./destroy.sh

scan:
	./test-security-app.sh

tailscale:
	./tailscale/install-operator.sh

status:
	kubectl get pods -A

access-info:
	./scripts/show-access-info.sh

validate-kustomize:
	@echo "Validating root kustomization..."
	kubectl kustomize . >/dev/null && echo "  ✓ Root overlay valid"
	@echo "Validating apps/demo overlay..."
	kubectl kustomize apps/demo >/dev/null && echo "  ✓ apps/demo valid"
	@echo "Validating rabbitmq overlay..."
	kubectl kustomize rabbitmq >/dev/null && echo "  ✓ rabbitmq valid"
	@echo "Validating headlamp overlay..."
	kubectl kustomize headlamp >/dev/null && echo "  ✓ headlamp valid"
	@echo "Validating openbao overlay..."
	kubectl kustomize openbao >/dev/null && echo "  ✓ openbao valid"
	@echo "Validating infrastructure overlay..."
	kubectl kustomize infrastructure >/dev/null && echo "  ✓ infrastructure valid"

sync:
	@echo "Triggering Flux reconciliation..."
	flux reconcile source git flux-system
	flux reconcile kustomization infrastructure
	flux reconcile kustomization apps

flux-status:
	flux get all

flux-diff:
	@echo "Diffing infrastructure..."
	flux diff kustomization infrastructure
	@echo "Diffing apps..."
	flux diff kustomization apps

help:
	@echo "Available targets:"
	@echo "  make up                - Deploy the full kind cluster and all components"
	@echo "  make down              - Tear down the kind cluster"
	@echo "  make scan              - Run the security scanner suite"
	@echo "  make tailscale         - Install the Tailscale Kubernetes Operator"
	@echo "  make status            - Show pod status across all namespaces"
	@echo "  make access-info       - Show URLs and port-forward instructions"
	@echo "  make validate-kustomize - Validate all Kustomize overlays"
	@echo "  make sync              - Trigger immediate Flux reconciliation"
	@echo "  make flux-status       - Show Flux resource status"
	@echo "  make flux-diff         - Show pending changes for Flux-managed resources"
