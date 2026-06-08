# code_server

Deploys [code-server](https://github.com/coder/code-server) (VS Code in the browser) as
**one rootless Podman Quadlet per developer**, each running under that developer's *own*
OS/IdM account. Every developer gets their own container, their own volumes, their own
Podman secret, and their own published port.

Every developer uses **one** hostname. Keycloak decides who you are, and Caddy routes you to
your own backend and nobody else's.

```
                                   ┌─ oauth2-proxy-code ──▶ Keycloak (who is this?)
                                   │      (caddy.network, no host port)
browser ──HTTPS──▶ Caddy ──forward_auth──┤
   code.lab.example.org  (desktop-2)     │
                                   └─ X-Auth-Request-Preferred-Username: alice
                                            │
                                            └──10.0.10.0/24──▶ code-server-alice (rootless, as alice)
```

## Authorization happens twice

1. **May you use code-server at all?** oauth2-proxy checks the Keycloak `groups` claim against
   the `code-server-users` IdM group. This is the same mechanism `ai_webui` uses for
   `webui-user` — except code-server has no OIDC of its own, so the proxy is the client.
   A user outside the group gets a **403** and never reaches a backend.
2. **Which workspace is yours?** Caddy matches the `X-Auth-Request-Preferred-Username` header
   that oauth2-proxy returns against each `code_server_users[].username` and proxies only to
   that developer's port. Authenticated but no workspace provisioned → **403**.

Then, behind both, code-server's own `--auth password`. Three gates, deliberately: the backend
port is reachable from `10.0.10.0/24`, so the password is what stands between a LAN host and an
IDE with a terminal if the proxy is ever bypassed.

## Why one rootless *account* per developer

Other multi-tenant roles here (`ai_gws`) run every per-user container under a single shared
service user; isolation is by container, volume, and secret naming. That is not enough for
an IDE: code-server hands its user a **terminal**, so the container is a shell by design.
If a developer escapes it, a shared service user would put them next to every *other*
developer's volumes.

Giving each developer their own rootless account means an escape lands you as that one
developer and nothing more. It also makes `UserNS=keep-id:uid=1000,gid=1000` do something
useful: the container's uid 1000 maps to the real host account, so files created under
`/workspaces` come out owned by the actual IdM user.

The cost, accepted deliberately: each rootless account has its own image store, so the
image is **built once per developer** (N builds, N copies on disk).

## Components (per developer `<u>`)

| Quadlet unit | Purpose |
|---|---|
| `code-server-<u>.container` | the IDE, listening on `code_server_port` inside the container |
| `code-server-<u>-config.volume` | `~/.local/share/code-server` — settings, keybindings, installed extensions |
| `code-server-<u>-data.volume` | `/workspaces` — the developer's actual work |

Plus a Podman secret `code-server-<u>-password`, injected as `$PASSWORD`, and a firewalld
rich rule allowing that developer's port only from `code_server_caddy_source`.

## What persists, and what does not

The volumes cover exactly two paths. **Everything else in the container is recreated from
the image on every container recreate**, which surprises people:

| Path | Persists? |
|---|---|
| `/workspaces` | ✅ the `-data` volume |
| `~/.local/share/code-server` (settings, extensions) | ✅ the `-config` volume |
| `~/.gitconfig`, `~/.ssh`, `~/.bash_history` | ❌ gone on recreate |
| `~/.config` (including `~/.config/mise`) | ❌ gone on recreate |
| mise tool installs under `~/.local/share/mise` | ❌ gone on recreate |

Tell developers: **keep anything durable under `/workspaces`.** If per-user dotfile
persistence is wanted later, add a third volume for `/home/ansible/.config` — it is a
deliberate omission, not an oversight.

## Prerequisites

1. **One OS/IdM account per developer**, matching `code_server_users[].username`. The role
   asserts the account exists; it does not create it.
2. **subuid/subgid ranges for each account.** IdM accounts do *not* get these automatically
   and rootless Podman cannot start a single container without them. The role asserts and
   fails with guidance rather than mutating IdM:
   ```bash
   ipa subid-add --owner=alice          # and set `subid: sss` in /etc/nsswitch.conf
   # or, for local accounts, add entries to /etc/subuid and /etc/subgid
   ```
   The role enables linger itself (`code_server_manage_linger`, default true).
3. **One DNS record** for `code_server_domain` (`code.lab.example.org`), pointing at the Caddy
   host. Not one per developer.
4. **A Keycloak client** (`code-server`) with a `groups` mapper *and* an audience mapper —
   oauth2-proxy's `keycloak-oidc` provider rejects every token without the latter.
5. **A `code-server-users` IdM group** containing the developers who may sign in.
6. **Caddy on the reverse-proxy host**, with a `caddy_oauth2_proxies` entry named `code` and
   the site block from `files/caddy_code_server.conf`. This role does not configure Caddy.

Because `full.path: false` is set on the realm's group mappers, the `groups` claim carries
bare names — so `allowed_groups` is `code-server-users`, **without** the leading slash that
oauth2-proxy's own documentation shows.

## Variables worth setting

| Variable | Default | Notes |
|---|---|---|
| `code_server_bind_address` | `''` | **Required.** The LAN IP *this* host publishes on. No fact fallback — the playbooks run `gather_facts: false`. |
| `code_server_users` | `[]` | **Required.** One entry per developer. |
| `code_server_caddy_source` | `10.0.10.0/24` | firewalld source for the published ports. Tighten to the Caddy host's `/32`. |
| `code_server_domain` | `code.lab.example.org` | The single vhost. Feeds `--trusted-origins`. |
| `code_server_version` | `4.127.0` | Drives the image tag *and* the RPM URL. |
| `code_server_selinux_home_equivalent` | `false` | Enable only if a developer's home is outside `/home`. |

Ports are **explicit per developer**, never derived from a base + index: reordering the
list must never silently reassign a port, because the port is also baked into that
developer's firewalld rule and Caddy site block.

`username` is the **routing key**, not just a label — Caddy matches it against Keycloak's
`preferred_username`. It must equal the developer's IdM uid exactly, or they will fall through
to the 403.

## Secrets (supply via AAP credential injectors / vault — never commit)

| Variable | Scope | How to obtain |
|---|---|---|
| `code_server_users[].password` | per developer | `openssl rand -base64 24` |

```yaml
code_server_bind_address: 10.0.10.21

code_server_users:
  - username: alice        # DNS-safe ^[a-z0-9-]+$ AND a real OS/IdM account
    port: 8443             # unique per developer
    password: "{{ _vault_code_server_alice_password }}"
  - username: bob
    port: 8444
    password: "{{ _vault_code_server_bob_password }}"
```

## Usage

```bash
ansible-playbook playbooks/code_server.yml \
  -e code_server_bind_address=10.0.10.21 \
  -e '{"code_server_users":[{"username":"alice","port":8443,"password":"..."}]}'
```

## Building the image

The image is the SOE workspace: UBI 9 + code-server + AAP tooling + RHOSO clients + mise.

**UBI 9, not the project-standard UBI 10**, because the AAP and RHOSO content is published
only for RHEL 9 (`ansible-automation-platform-2.7-for-rhel-9-x86_64-rpms`,
`rhoso-tools-18-for-rhel-9-x86_64-rpms`).

> ⚠️ **This is the most likely thing to break.** A rootless `podman build` from a UBI 9 base
> on a RHEL 10 host does **not** automatically get RHEL 9 entitlements or those repo
> definitions — UBI ships only the UBI repos. Expect `There are no enabled repositories`
> from the AAP layer. Verify with a single manual build before rolling this out:
>
> ```bash
> sudo -iu alice
> podman build --build-arg CODE_SERVER_VERSION=4.127.0 -t localhost/code-server:4.127.0 /var/lib/code-server/build
> podman run --rm localhost/code-server:4.127.0 code-server --version
> ```
>
> If the AAP layer fails, the options are: stage a Satellite `.repo` file into the build
> context (this is precisely why the role stages `ca-certs/ca.crt` — build-time `dnf` needs
> to trust Satellite, and the Quadlet's runtime CA bind-mount comes far too late); build on
> a RHEL 9 host; inject `/etc/pki/entitlement` as a build secret; or drop the AAP/RHOSO
> layers and install that tooling via `pip`/`mise` instead.

code-server itself is installed from the upstream **RPM** pinned to `code_server_version`,
not the vendor's `curl | sh` installer, per the project container standard.

## Verify

```bash
sudo -iu alice
systemctl --user status code-server-alice.service
podman volume ls                          # only alice's -config and -data
podman secret ls                          # code-server-alice-password
podman healthcheck run code-server-alice  # healthy once /healthz responds
```

The password must never appear inline in the rendered unit — only as a secret reference:

```bash
grep -i password ~alice/.config/containers/systemd/code-server-alice.container
# -> Secret=code-server-alice-password,type=env,target=PASSWORD
```

Reachability and the firewall rule, from the Caddy host and then from a host *outside*
`code_server_caddy_source`:

```bash
curl -fsI http://10.0.10.21:8443/healthz   # 200 from the Caddy host
curl -fsI http://10.0.10.21:8443/healthz   # refused from anywhere else
```

Then the SSO path, end to end:

```bash
# No session -> 302 to sign-in, never a bare 401
curl -sI https://code.lab.example.org/ | head -1

# Spoofing the identity header must NOT reach alice's backend
curl -sI -H 'X-Auth-Request-Preferred-Username: alice' https://code.lab.example.org/ | head -1
```

Both must redirect to `/oauth2/start`. Then sign in as alice and confirm the code-server
password prompt appears; `podman logs code-server-bob` on the backend host must stay silent.
Remove a developer from `code-server-users`, re-authenticate, and confirm a **403** — not a
redirect loop.

## Design decisions

- **`--auth password` stays even behind SSO.** Two prompts per login, on purpose. It is the
  last gate if the reverse proxy is bypassed or misconfigured, and it costs one Podman secret.
- **Caddy matches `401` only, never `4xx`.** oauth2-proxy answers `/oauth2/auth` with 401 for
  "no session" and **403** for "signed in, wrong group". Redirecting a 403 to `/oauth2/start`
  would bounce off the user's already-valid session and loop forever; it must fall through to
  the browser instead.
- **The header strip lives inside `route { }`.** `request_header` sorts *after* `forward_auth`
  in Caddy's default directive order, so outside a `route` it would delete the identity headers
  `forward_auth` had just set. `route` executes directives in written order.
- **`/healthz` is the healthcheck.** It is served unauthenticated, so the probe needs no
  credential; it checks liveness only. Probe the *container* port, never the published one.
- **`--bind-addr` is not redundant with `config.yaml`.** It keeps the argument count above
  one, which keeps code-server off the `shouldOpenInExistingInstance()` branch.

## Out of scope / future enhancements

- **Dotfile / mise persistence** — see the persistence table above.
- **A shared image store** (`additionalimagestores`) to collapse the N per-developer image
  copies into one, if disk pressure appears.
- **Sharing one oauth2-proxy across apps.** Each protected vhost currently gets its own
  instance and its own Keycloak client. A central `auth.lab.example.org` with a shared cookie
  domain would collapse them, at the cost of coupling every app to one session.
