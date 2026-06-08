# caddy

Deploys [Caddy](https://caddyserver.com) as a rootless Podman Quadlet: a TLS-terminating
reverse proxy for every self-hosted service in the site. Optionally deploys one
[oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) sidecar per protected vhost, so
Caddy can put Keycloak SSO in front of applications that have no OIDC of their own.

## Caddyfile

`caddy_domains` is a list of raw Caddyfile blocks, concatenated verbatim into
`{{ caddy_config_dir }}/Caddyfile`. Entries are Jinja-templated, so they may reference other
inventory variables. The first entry is conventionally the global options block or a shared
snippet:

```yaml
caddy_domains:
  - |
    (idm_caddy_acme_ca) {
      tls {
        ca https://idm-1.dc1.lab.example.org/acme/directory
        ca_root /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        key_type rsa4096      # IdM ACME rejects Caddy's default ECDSA
      }
    }
  - |
    git.lab.example.org {
      import idm_caddy_acme_ca
      reverse_proxy http://10.0.10.11:3000
    }
```

Address backends by **LAN IP**, not `127.0.0.1`: Caddy runs in a container, so loopback is its
own network namespace, not the host's.

## Forward auth (Keycloak SSO)

The stock `docker.io/caddy:latest` image carries no auth plugin, and adding one would mean an
`xcaddy` rebuild. But `forward_auth` is a **core** directive, so Caddy can delegate "who is
this?" to a sidecar on every request. `caddy_oauth2_proxies` deploys one such sidecar per
protected vhost — each is the Keycloak OIDC client that the protected app cannot be.

```yaml
caddy_oauth2_proxies:
  - name: code                         # -> container + DNS name oauth2-proxy-code
    domain: code.lab.example.org       # drives the redirect URI
    port: 4180                         # container-internal only; never published
    allowed_groups:
      - code-server-users              # `groups` claim; NO leading slash
    client_id: "{{ _vault_code_server_oauth_client_id }}"
    client_secret: "{{ _vault_code_server_oauth_client_secret }}"
    cookie_secret: "{{ _vault_code_server_cookie_secret }}"
```

When the list is non-empty the role creates a `{{ caddy_network }}.network` Quadlet and joins
both Caddy and the sidecars to it, so Caddy reaches them **by container name**. The sidecars
therefore publish no host port and are unreachable from the LAN. When the list is empty nothing
changes: no network is created and Caddy keeps podman's default networking.

Secrets become Podman secrets (`oauth2-proxy-<name>-client-id`, `-client-secret`,
`-cookie-secret`) and are injected as `OAUTH2_PROXY_*` environment variables. They never appear
in a unit file.

### Things that will bite you

- **Match `401`, not `4xx`.** `/oauth2/auth` returns 401 for "no session" and **403** for
  "signed in, but not in `allowed_groups`". Redirecting a 403 to `/oauth2/start` bounces off the
  user's valid session and loops forever. Let 403 reach the browser.
- **Strip inbound identity headers inside `route { }`.** `request_header` sorts *after*
  `forward_auth` in Caddy's default directive order, so outside a `route` block it would delete
  the very headers `forward_auth` just copied. `route` runs directives in written order.
- **`allowed_groups` takes bare names.** oauth2-proxy's docs show `--allowed-group=/name`, which
  assumes Keycloak's default full-path group claim. This site's group mappers set
  `full.path: false`, so use `code-server-users`, not `/code-server-users`.
- **`keycloak-oidc` requires an audience mapper** on the Keycloak client. Without it every token
  is rejected as wrong-audience. Copy the `oidc-audience-mapper` pattern from the `netbird`
  client in `group_vars/keycloak/clients.yml`.
- **No healthcheck on the sidecar.** The upstream image is distroless — only `/bin/oauth2-proxy`,
  no shell or curl — so an in-container probe cannot run. `/ping` is still served for external
  checks. Use the `-alpine` tag if you need `HealthCmd`.

A complete worked site block lives in `roles/code_server/files/caddy_code_server.conf`.

## Validate before you deploy

A malformed Caddyfile takes the whole proxy down, so check it first:

```bash
podman run --rm -v ./Caddyfile:/etc/caddy/Caddyfile:ro,Z docker.io/caddy:latest \
  caddy validate --config /etc/caddy/Caddyfile
```

`caddy adapt --config Caddyfile` prints the resulting JSON, which is the only reliable way to
confirm that handlers ended up in the order you intended.

## Verify

```bash
sudo -iu caddy
systemctl --user status caddy.service
podman exec caddy wget -qO- http://oauth2-proxy-code:4180/ping   # -> OK (name resolution works)
podman secret ls                                                  # the three oauth2-proxy secrets
```

From any other host, the sidecar must be unreachable:

```bash
curl --connect-timeout 3 http://10.0.10.12:4180/ping   # must fail to connect
```
