.PHONY: up down scan tailscale status help

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

help:
	@echo "Available targets:"
	@echo "  make up        - Deploy the full kind cluster and all components"
	@echo "  make down      - Tear down the kind cluster"
	@echo "  make scan      - Run the security scanner suite"
	@echo "  make tailscale - Install the Tailscale Kubernetes Operator"
	@echo "  make status    - Show pod status across all namespaces"
