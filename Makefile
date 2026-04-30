.PHONY: up down scan tailscale status access-info help

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

help:
	@echo "Available targets:"
	@echo "  make up         - Deploy the full kind cluster and all components"
	@echo "  make down       - Tear down the kind cluster"
	@echo "  make scan       - Run the security scanner suite"
	@echo "  make tailscale  - Install the Tailscale Kubernetes Operator"
	@echo "  make status     - Show pod status across all namespaces"
	@echo "  make access-info - Show URLs and port-forward instructions"
