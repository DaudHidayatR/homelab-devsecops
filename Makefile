.PHONY: up down scan tailscale status access-info help validate-kustomize sync flux-status flux-diff security sast secrets sca sbom iac validate clean

up:
	./setup.sh

down:
	./destroy.sh

scan:
	bash scripts/security-scan.sh

tailscale:
	./tailscale/install-operator.sh

status:
	kubectl get pods -A

access-info:
	./scripts/show-access-info.sh

validate-kustomize:
	@echo "Validating cluster entrypoint overlay..."
	kubectl kustomize clusters/kind >/dev/null && echo "  ✓ clusters/kind valid"
	@echo "Validating root fallback aggregate..."
	kubectl kustomize . >/dev/null && echo "  ✓ Root overlay valid"
	@echo "Validating Flux apps overlay..."
	kubectl kustomize apps >/dev/null && echo "  ✓ apps valid"
	@echo "Validating apps/demo overlay..."
	kubectl kustomize apps/demo >/dev/null && echo "  ✓ apps/demo valid"
	@echo "Validating apps/rabbitmq overlay..."
	kubectl kustomize apps/rabbitmq >/dev/null && echo "  ✓ apps/rabbitmq valid"
	@echo "Validating apps/headlamp overlay..."
	kubectl kustomize apps/headlamp >/dev/null && echo "  ✓ apps/headlamp valid"
	@echo "Validating apps/openbao overlay..."
	kubectl kustomize apps/openbao >/dev/null && echo "  ✓ apps/openbao valid"
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

security: ## Run full security scan suite
	@bash scripts/security-scan.sh

sast: ## Run SAST only (Semgrep)
	@bash scripts/security-scan.sh semgrep

secrets: ## Run secret detection only (GitLeaks)
	@bash scripts/security-scan.sh gitleaks

sca: ## Run SCA only (Trivy + Grype)
	@bash scripts/security-scan.sh trivy
	@bash scripts/security-scan.sh grype

sbom: ## Generate SBOMs only (Syft)
	@bash scripts/security-scan.sh syft

iac: ## Run IaC scan only (Kustomize)
	@bash scripts/security-scan.sh kustomize

validate: ## Validate report files exist
	@bash scripts/security-scan.sh validate

clean: ## Remove generated reports
	rm -f trivy-report.json trivy-report.sarif trivy-report.txt
	rm -f trivy-rendered.sarif
	rm -f grype-report.json
	rm -f gitleaks-report.json
	rm -f semgrep-report.json semgrep-report.sarif semgrep-report.txt
	rm -f sbom-spdx.json sbom-cyclonedx.json

help: ## Show this help
	@echo "Available targets:"
	@echo "  make up                  - Deploy the full kind cluster and all components"
	@echo "  make down                - Tear down the kind cluster"
	@echo "  make scan                - Run the security scanner suite"
	@echo "  make tailscale           - Install the Tailscale Kubernetes Operator"
	@echo "  make status              - Show pod status across all namespaces"
	@echo "  make access-info         - Show URLs and port-forward instructions"
	@echo "  make validate-kustomize  - Validate all Kustomize overlays"
	@echo "  make sync                - Trigger immediate Flux reconciliation"
	@echo "  make flux-status         - Show Flux resource status"
	@echo "  make flux-diff           - Show pending changes for Flux-managed resources"
	@echo "  make security            - Run full security scan suite (SAST + Secrets + SCA + IaC + SBOM)"
	@echo "  make sast                - Run SAST only (Semgrep)"
	@echo "  make secrets             - Run secret detection only (GitLeaks)"
	@echo "  make sca                 - Run SCA only (Trivy + Grype)"
	@echo "  make sbom                - Generate SBOMs only (Syft)"
	@echo "  make iac                 - Run IaC scan only (Kustomize)"
	@echo "  make validate            - Validate report files exist"
	@echo "  make clean               - Remove generated reports"
