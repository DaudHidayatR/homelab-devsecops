.PHONY: up down scan tailscale tailscale-reset tailscale-sign tailscale-check status access-info help validate-kustomize sync redeploy flux-status flux-diff security sast secrets sca sbom iac validate clean prune-branches prune-branches-force tag openbao-policies openbao-status openbao-create-user openbao-create-approle lint-sh fmt-sh check-sh syntax-sh

up:
	./scripts/cluster/setup.sh

down:
	./scripts/cluster/destroy.sh

scan:
	bash scripts/security/scan.sh

tailscale:
	./scripts/tailscale/install-operator.sh

tailscale-reset:
	./scripts/tailscale/reset-proxies.sh

tailscale-sign:
	./scripts/tailscale/sign-proxies.sh --sudo

tailscale-check:
	./scripts/tailscale/check-access.sh

status:
	kubectl get pods -A

access-info:
	./scripts/access/show-info.sh

openbao-policies:
	bash scripts/openbao/apply-policies.sh

openbao-status:
	bash scripts/openbao/status.sh

openbao-create-user:
	@if [ -z "$(USER)" ] || [ -z "$(PASSWORD)" ]; then \
		echo "Usage: make openbao-create-user USER=<username> PASSWORD=<password> [POLICY=default-user] [SSH=true]"; \
		exit 1; \
	fi
	bash scripts/openbao/create-user.sh "$(USER)" "$(PASSWORD)" "$(or $(POLICY),default-user)" $(if $(filter true,$(SSH)),--ssh,)

openbao-create-approle:
	@if [ -z "$(ROLE)" ] || [ -z "$(POLICY)" ]; then \
		echo "Usage: make openbao-create-approle ROLE=<role-name> POLICY=<policy>"; \
		exit 1; \
	fi
	bash scripts/openbao/create-approle.sh "$(ROLE)" "$(POLICY)"

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
	@echo "Validating infrastructure overlay..."
	kubectl kustomize infrastructure >/dev/null && echo "  ✓ infrastructure valid"
	@echo "Validating infrastructure/openbao overlay..."
	kubectl kustomize infrastructure/openbao >/dev/null && echo "  ✓ infrastructure/openbao valid"
	@echo "Validating infrastructure/external-secrets overlay..."
	kubectl kustomize infrastructure/external-secrets >/dev/null && echo "  ✓ infrastructure/external-secrets valid"

sync:
	@if command -v flux >/dev/null 2>&1 && kubectl get namespace flux-system >/dev/null 2>&1; then \
		echo "Triggering Flux reconciliation..."; \
		flux reconcile source git flux-system; \
		flux reconcile kustomization infrastructure; \
		flux reconcile kustomization apps; \
	else \
		echo "Flux CLI or flux-system namespace not available; applying apps overlay with kubectl."; \
		kubectl apply -k apps; \
	fi

redeploy: sync
	@echo "Safe app redeploy complete. Cluster and Tailscale state were preserved."

flux-status:
	flux get all

flux-diff:
	@echo "Diffing infrastructure..."
	flux diff kustomization infrastructure
	@echo "Diffing apps..."
	flux diff kustomization apps

security: ## Run full security scan suite
	@bash scripts/security/scan.sh

sast: ## Run SAST only (Semgrep + Checkov)
	@bash scripts/security/scan.sh semgrep
	@bash scripts/security/scan.sh checkov

secrets: ## Run secret detection only (GitLeaks)
	@bash scripts/security/scan.sh gitleaks

sca: ## Run SCA only (Trivy + Grype)
	@bash scripts/security/scan.sh trivy
	@bash scripts/security/scan.sh grype

sbom: ## Generate SBOMs only (Syft)
	@bash scripts/security/scan.sh syft

iac: ## Run IaC scan only (Kustomize)
	@bash scripts/security/scan.sh kustomize

validate: ## Validate report files exist
	@bash scripts/security/scan.sh validate

clean: ## Remove generated reports
	rm -f trivy-report.json trivy-report.sarif trivy-report.txt
	rm -f trivy-rendered.sarif
	rm -f grype-report.json
	rm -f gitleaks-report.json
	rm -f semgrep-report.json semgrep-report.sarif semgrep-report.txt
	rm -f checkov-report.json checkov-report.sarif
	rm -f sbom-spdx.json sbom-cyclonedx.json

prune-branches: ## Show local branches merged into main, prune deleted remote tracking refs
	@echo "Fetching and pruning deleted remote branches..."
	git fetch --prune
	@echo ""
	@echo "Local branches already merged into main:"
	@git -c color.ui=never branch --merged main | grep -v '^\*' | grep -v 'main' || echo "  (none)"
	@echo ""
	@echo "Run 'make prune-branches-force' to delete them."

prune-branches-force: ## Delete local branches merged into main (non-interactive)
	@echo "Deleting local branches merged into main..."
	git -c color.ui=never branch --merged main | grep -v '^\*' | grep -v 'main' | xargs -r git branch -d 2>/dev/null || true
	@echo ""
	@echo "Any branches not deleted above have unmerged changes on a fork/upstream."
	@echo "Review them manually: git branch -a"

tag: ## Tag current HEAD and push for Flux semver deploy (usage: make tag v=0.0.1)
	@if [ -z "$(v)" ]; then \
		echo "Usage: make tag v=<version>"; \
		echo "Example: make tag v=0.0.1"; \
	else \
		git tag -a "$(v)" -m "Deploy: $(v)" && git push origin "$(v)"; \
	fi

check-sh: ## Validate shell formatting and linting
	@SHELL_SCRIPTS="$$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r script; do [ -f "$$script" ] && printf '%s\n' "$$script"; done)"; \
	command -v shfmt >/dev/null 2>&1 || { echo "shfmt is required for check-sh"; exit 1; }; \
	command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is required for check-sh"; exit 1; }; \
	shfmt -i 2 -ci -bn -d $$SHELL_SCRIPTS; \
	shellcheck $$SHELL_SCRIPTS

fmt-sh: ## Format shell scripts
	@SHELL_SCRIPTS="$$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r script; do [ -f "$$script" ] && printf '%s\n' "$$script"; done)"; \
	command -v shfmt >/dev/null 2>&1 || { echo "shfmt is required for fmt-sh"; exit 1; }; \
	shfmt -i 2 -ci -bn -w $$SHELL_SCRIPTS

lint-sh: ## Run ShellCheck for shell scripts
	@SHELL_SCRIPTS="$$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r script; do [ -f "$$script" ] && printf '%s\n' "$$script"; done)"; \
	command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is required for lint-sh"; exit 1; }; \
	shellcheck $$SHELL_SCRIPTS

syntax-sh: ## Run bash syntax checks for shell scripts
	@SHELL_SCRIPTS="$$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r script; do [ -f "$$script" ] && printf '%s\n' "$$script"; done)"; \
	for script in $$SHELL_SCRIPTS; do \
		bash -n "$$script" || exit 1; \
	done

help: ## Show this help
	@echo "Available targets:"
	@echo "  make up                  - Deploy the full kind cluster and all components"
	@echo "  make down                - Tear down the kind cluster (backs up Tailscale state first)"
	@echo "  make redeploy            - Safely redeploy apps via Flux without destroying Tailscale state"
	@echo "  make scan                - Run the security scanner suite"
	@echo "  make tailscale           - Install the Tailscale Kubernetes Operator"
	@echo "  make tailscale-reset     - Reset stale Kubernetes Tailscale proxy identities"
	@echo "  make tailscale-sign      - Sign Kubernetes Tailscale proxy nodes for Tailnet Lock"
	@echo "  make tailscale-check     - Check Tailscale DNS, Serve config, and HTTPS access"
	@echo "  make status              - Show pod status across all namespaces"
	@echo "  make access-info         - Show URLs and port-forward instructions"
	@echo "  make openbao-policies    - Apply OpenBao policy-as-code files"
	@echo "  make check-sh            - Validate shell formatting and ShellCheck linting"
	@echo "  make fmt-sh              - Format shell scripts with shfmt"
	@echo "  make lint-sh             - Run ShellCheck for shell scripts"
	@echo "  make syntax-sh           - Run bash syntax checks for shell scripts"
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
	@echo "  make prune-branches      - Show local branches merged into main"
	@echo "  make prune-branches-force - Delete local branches merged into main"
	@echo "  make tag v=<version>     - Tag current HEAD and push for Flux semver deploy"
