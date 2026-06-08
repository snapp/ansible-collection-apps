# ai_gws

Deploys [aaronsb/google-workspace-mcp](https://github.com/aaronsb/google-workspace-mcp)
as **one isolated rootless Podman Quadlet per Google account**, each bridged to Open WebUI
with [mcpo](https://github.com/open-webui/mcpo) and exposed as its own OpenAPI/HTTP tool
endpoint. The role is part of the **AI stack**: it runs as the same rootless `ai` user as
`ai_webui`/`ai_inference`, joins the shared `ai.network`, and uses `ai-` naming.

```
Open WebUI ──HTTP+Bearer (ai.network)──▶ mcpo (per user) ──stdio──▶ google-workspace-mcp ──▶ gws ──▶ Google APIs
```

## Why one container per account (multi-tenant isolation)

The hard requirement is that **no Open WebUI user can ever reach another user's Google
data** — not through the UI, a crafted tool call, or prompt injection. Two upstream facts
make a shared backend unsafe, so isolation is **physical**:

1. Open WebUI does not forward trustworthy per-user identity to tool backends
   ([open-webui #21184](https://github.com/open-webui/open-webui/discussions/21184)); the
   Bearer token it sends is internally generated, and container env is fixed at start, not
   per request. A shared backend cannot know *which* user is calling.
2. `google-workspace-mcp`'s multi-account routing is a **tool-call parameter** — the LLM
   (and thus prompt injection) picks the account. A single-account container has no account
   parameter to abuse.

So the boundary is: **one container = exactly one account's tokens = one distinct mcpo
Bearer key = one Open WebUI tool connection, ACL'd to one user.** Even an ACL bug can't
leak another account, because the container simply doesn't hold anyone else's tokens.

## Components (per user `<u>`)

| Quadlet unit | Purpose |
|---|---|
| `ai-gws-<u>.container` | mcpo bridging one `google-workspace-mcp` stdio server |
| `ai-gws-<u>-config.volume` | `~/.config` — account registry (`accounts.json`) + gws CLI store |
| `ai-gws-<u>-data.volume` | `~/.local/share` — this account's OAuth tokens |

Built once and shared by every container: the image `localhost/ai-gws:<version>`
(mcpo + `google-workspace-mcp` + the `gws` CLI, on UBI 10). Shared Podman secrets:
`ai-gws-google-client-id` / `ai-gws-google-client-secret` (the one GCP OAuth *app*).

### A note on the network boundary

These containers share the flat `ai.network` with Open WebUI and the inference containers
(the AI stack's convention) rather than a dedicated segment. Any co-tenant can therefore
*attempt* to connect to a `ai-gws-<u>` endpoint — but each requires that container's own
random Bearer key and only ever returns its single account's data, so the isolation
guarantee holds. Use strong per-user keys (`openssl rand -hex 32`). This model suits
single- to low-double-digit users; hundreds of users would want a multi-tenant gateway
with per-user OAuth, which depends on Open WebUI identity forwarding not yet available.

## Prerequisites

1. **AI stack present on the host** — `ai_inference` must have run first (it creates
   `ai.network`), and typically `ai_webui`. `ai_gws` only joins that network.
2. **`ai` IdM service user** with subuid/subgid ranges; the role enables linger.
3. **One Google Cloud OAuth client** (Desktop/Installed-app type) in a single GCP project,
   shared by all containers → `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`. Grant only
   read-only Workspace scopes for the default read-only posture.
4. **A distinct mcpo Bearer key per user** (`openssl rand -hex 32`).

## Secrets (supply via AAP credential injectors / vault — never commit)

| Variable | Scope | How to obtain |
|---|---|---|
| `ai_gws_google_client_id` | shared | GCP Console → APIs & Services → Credentials |
| `ai_gws_google_client_secret` | shared | same OAuth client |
| `ai_gws_users[].api_key` | per user | `openssl rand -hex 32` |

Define the tenants (e.g. in `group_vars`/`host_vars` of the AI host):

```yaml
ai_gws_google_client_id: "{{ _vault_ai_gws_google_client_id }}"
ai_gws_google_client_secret: "{{ _vault_ai_gws_google_client_secret }}"

ai_gws_users:
  - username: alice                 # DNS-safe: ^[a-z0-9-]+$
    google_account: alice@example.org
    owui_group: gws-alice           # the Open WebUI group-of-one to ACL to
    api_key: "{{ _vault_ai_gws_alice_api_key }}"
  - username: bob
    google_account: bob@example.org
    owui_group: gws-bob
    api_key: "{{ _vault_ai_gws_bob_api_key }}"
```

## Usage

```yaml
- name: Deploy Google Workspace MCP tool servers
  hosts: ai_webui
  become: true
  tasks:
    - name: Per-account tool servers
      ansible.builtin.include_role:
        name: infra.apps.ai_gws
```

Or run the bundled playbook (asserts the required secrets):

```bash
ansible-playbook playbooks/ai_gws.yml \
  -e ai_gws_google_client_id=... -e ai_gws_google_client_secret=... \
  -e '{"ai_gws_users":[{"username":"alice","google_account":"alice@example.org","api_key":"..."}]}'
```

## First-run OAuth bootstrap (once per account)

Adding a Google account is interactive (a browser consent). Do it once per container;
tokens then persist in that user's volumes across restarts.

```bash
# As the ai user on the host, exec into that user's container:
sudo -iu ai
podman exec -it ai-gws-alice google-workspace-mcp   # or drive the tool via mcpo /docs

# Trigger authentication (via the MCP tool call), e.g.:
#   manage_accounts { "operation": "authenticate", "account": "alice@example.org" }
# Copy the emitted OAuth URL, open it in a workstation browser, and consent AS alice.
```

Complete the consent as **that** Google account only — one account per container. The
resulting tokens are written to `ai-gws-alice-data` / `ai-gws-alice-config` and survive
restarts and image bumps.

## Verify

```bash
sudo -iu ai
systemctl --user status ai-gws-alice
podman healthcheck run ai-gws-alice        # -> healthy once /docs responds

# From inside the Open WebUI container (same ai.network), by name, with the key:
podman exec ai-webui curl -fsS -H "Authorization: Bearer <alice-key>" \
  http://ai-gws-alice:8600/docs
podman exec ai-webui curl -fsS -H "Authorization: Bearer <alice-key>" \
  http://ai-gws-alice:8600/google-workspace/openapi.json
```

A request with the wrong key must be rejected (401), and `ai-gws-alice` must never return
data for any account other than alice's.

## Open WebUI registration (one connection per user)

For **each** container, add a **separate** global External Tool (OpenAPI) connection —
never a shared one:

1. Admin Settings → External Tools → add an **OpenAPI** connection:
   - URL: `http://ai-gws-<username>:8600`
   - Auth: **Bearer**, that user's `api_key`.
2. Scope it with **Access Control** to that user's group-of-one (`owui_group`).
3. Attach it only to that user's model(s).

## Design decisions

- **Read-only by default.** The authoritative control is granting only read-only Google
  scopes at consent (enforced by Google). `ai_gws_disabled_tools` is offered as an
  mcpo-level `disabledTools` guard; confirm exact tool names before relying on it.
- **No RHBK / Caddy.** This is a machine-to-machine, internal-network endpoint secured by
  a per-container Bearer key. Open WebUI's server-to-server tool calls cannot complete an
  interactive OIDC redirect, so an API-key design is preferred; no external exposure.
- **Image on UBI 10.** Built from `registry.access.redhat.com/ubi10` per the project
  container standard rather than layering on the upstream Debian mcpo image.

## Out of scope / future enhancements

- **Per-user read/write split** — a second write-scoped instance per user (e.g.
  `ai-gws-<u>-rw`) with a write-scoped OAuth grant. All users default to read-only for now.
- **Open WebUI model/tool assignment automation** — registration/ACL is manual (above).
- **systemd socket-activation / idle-stop** to reclaim RAM (~200–300 MB per container) if
  many instances run and memory pressure appears.
