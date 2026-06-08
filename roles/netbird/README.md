# netbird

Deploys a fully self-hosted [NetBird](https://netbird.io) mesh-VPN control plane
as **rootless Podman Quadlets**, federated to Red Hat Build of Keycloak (RHBK) for
authentication. The stack runs as a dedicated rootless IdM user (`netbird`), in the
same style as the `caddy` and `ai_webui` roles.

## Components

| Quadlet unit | Image | Role |
|---|---|---|
| `netbird.network` | — | Isolated bridge for the web-plane containers |
| `netbird-mgmt.volume` | — | Persists the Management SQLite store + keys |
| `netbird-management.container` | `netbirdio/management` | Control plane, REST + gRPC API, OIDC |
| `netbird-signal.container` | `netbirdio/signal` | WireGuard handshake brokering |
| `netbird-dashboard.container` | `netbirdio/dashboard` | Web UI (PKCE login) |
| `netbird-coturn.container` | `coturn/coturn` | STUN/TURN relay (P2P fallback, host net) |

TLS is terminated by the **`caddy`** role using the Let's Encrypt **DNS-01** challenge
for `netbird.ite.example.org`. See [`files/caddy_netbird.conf`](files/caddy_netbird.conf)
for the site block to add to `caddy_domains`.

## Prerequisites

1. **IdM service user** with linger enabled:
   ```bash
   ipa user-add netbird --shell=/sbin/nologin --home=/var/lib/netbird
   loginctl enable-linger netbird
   ```
2. **Keycloak clients** in the realm `netbird`:
   - `netbird` — public (PKCE) client; add the device-authorization grant and
     redirect URIs `http://localhost:53000`. Used by the dashboard and native clients.
   - `netbird-backend` — confidential client (service account / `client_credentials`)
     with `view-users` + `query-groups` on the `realm-management` client. Used by the
     Management IdP sync.
3. **Caddy image** built with the `caddy-dns/cloudflare` plugin and a
   `CLOUDFLARE_API_TOKEN` (Zone.DNS:Edit) supplied as a Podman secret/env var.

## Secrets (supply via AAP credential injectors as extra_vars — never commit)

| Variable | How to generate |
|---|---|
| `netbird_relay_secret` | `openssl rand -base64 32` |
| `netbird_turn_password` | `openssl rand -base64 32` |
| `netbird_datastore_encryption_key` | `openssl rand -base64 32` |
| `netbird_oidc_backend_client_secret` | Keycloak → `netbird-backend` → Credentials |

The role renders `management.json` and `turnserver.conf` with these values into
`/var/lib/netbird/config` (mode `0600`, `container_file_t`, `no_log: true`). They are
never written to job output and never enter the repo.

## Usage

```yaml
- name: Deploy NetBird
  hosts: ite
  tasks:
    - name: NetBird mesh VPN
      ansible.builtin.include_role:
        name: infra.apps.netbird
```

Run with secrets injected by AAP, or for a local PoC:

```bash
ansible-playbook playbooks/deploy_netbird.yml \
  -e netbird_relay_secret=... \
  -e netbird_turn_password=... \
  -e netbird_datastore_encryption_key=... \
  -e netbird_oidc_backend_client_secret=...
```

> **NOTE** Override `netbird_domain`, `netbird_oidc_base_url`, and `netbird_oidc_realm`
> in `group_vars` for your environment, and pin the `*_image` tags before production.
