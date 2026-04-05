# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind`, Istio, and RabbitMQ. Designed for learning service mesh basics and asynchronous messaging without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI
- `istioctl` CLI

## Project Structure
The configuration is modularized into logical directories:
- `kind/`: Cluster bootstrapping configurations.
- `istio/`: Declarative `istiod` control plane configuration.
- `rabbitmq/`: RabbitMQ message broker manifests in a dedicated namespace (kept outside the mesh).
- `headlamp/`: Kubernetes Web UI manifests for visual management.
- `apps/`: Application deployments structured by `namespace/service`.

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

## Accessing RabbitMQ
RabbitMQ is deployed to the `messaging` namespace.

1. Port-forward the RabbitMQ Management UI:
   ```bash
   kubectl port-forward -n messaging svc/rabbitmq 15672:15672
   ```
2. Open [http://localhost:15672](http://localhost:15672) in your browser.
3. Log in with the default credentials:
   - Username: `admin`
   - Password: `password123`

### Inter-Service Communication
Your microservices can connect to RabbitMQ using the internal cluster DNS:
```
RABBITMQ_URL=amqp://admin:password123@rabbitmq.messaging.svc.cluster.local:5672
```

## Tear Down
To destroy the local infrastructure and free up resources, run the destroy script:
```bash
./destroy.sh
```
