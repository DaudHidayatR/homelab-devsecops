# Tailscale Kubernetes Operator

This directory contains the installation script for the Tailscale Kubernetes Operator, which exposes cluster Services directly to your tailnet (or the public internet) without traditional ingress controllers, LoadBalancers, or public IPs.

## Two-Tier Access Architecture

| Tier | Annotation | Access Level | Use Case |
|------|-----------|--------------|----------|
| **Private** | `tailscale.com/expose: "true"` | Tailnet only | Headlamp, OpenBao, RabbitMQ admin |
| **Public** | `tailscale.com/funnel: "true"` | Internet (anyone) | Portfolio, public APIs, demo sites |

Both tiers use the **same** operator. Upgrading from private to public is a one-line annotation change.

## Prerequisites

1. A Tailscale account and an existing tailnet.
2. An OAuth client or auth key from the Tailscale admin console.

## Installation

1. Create the OAuth credentials secret:
   ```bash
   kubectl create secret generic operator-oauth \
     --namespace tailscale \
     --from-literal=client_id=<OAUTH_CLIENT_ID> \
     --from-literal=client_secret=<OAUTH_CLIENT_SECRET>
   ```

2. Run the installer:
   ```bash
   ./tailscale/install-operator.sh
   ```

## How It Works

When the operator is running, any Service with the `tailscale.com/expose: "true"` annotation automatically gets:

- A Tailscale proxy pod in the same namespace.
- A stable HTTPS hostname: `https://<service>-<namespace>.<tailnet>.ts.net`.
- Zero manual DNS or certificate management.

## Security Notes

- Admin tools (Headlamp, OpenBao, RabbitMQ) use the **private** tier (`expose`).
- Only promote to **public** (`funnel`) for services that are intentionally public.
- Tailscale ACLs still govern which tailnet users can reach exposed services.
