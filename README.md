# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind` and Istio. Designed for learning service mesh basics without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI
- `istioctl` CLI

## Usage
1. Make the scripts executable:
   ```bash
   chmod +x setup.sh destroy.sh
   ```
2. Run the automated setup:
   ```bash
   ./setup.sh
   ```

## Accessing Headlamp (Kubernetes Web UI)
This setup includes Headlamp to manage your cluster visually.

1. Port-forward the Headlamp service:
   ```bash
   kubectl port-forward -n kube-system service/headlamp 8080:80
   ```
2. In a new terminal, generate a login token:
   ```bash
   kubectl create token headlamp-admin -n kube-system
   ```
3. Open [http://localhost:8080](http://localhost:8080) in your browser and paste the token to log in.

## Tear Down
To destroy the local infrastructure and free up resources, run the destroy script:
```bash
./destroy.sh
```
