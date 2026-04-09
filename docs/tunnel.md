# Doey Tunnel — reach your remote dev server from your laptop

> Run `pnpm dev` on a Hetzner box, click a URL on your laptop, get HMR. Zero per-port
> config, works for any number of dev servers in a monorepo.

When you run Doey on a remote Linux host, any dev server you start inside a pane is
bound to that host's localhost — unreachable from your laptop browser. `doey tunnel`
fixes that. It uses Tailscale as the transport (one encrypted mesh, all ports exposed
transparently) and ships a port watcher that detects freshly-started dev servers,
writes out `http://<magic-dns>:<port>` URLs, and surfaces them in the Info Panel.

## How it works

- **Tailscale provides the transport.** One `tailscale up` on the remote host and every
  port on that host is reachable from any other device on your tailnet — no per-port
  setup, no reverse proxies, no public URLs.
- **A port watcher runs in the background.** `doey tunnel up` spawns a small bash
  daemon that polls `ss -tlnp` every 2 seconds, filters listeners by process name,
  and writes the detected ports to `/tmp/doey/<project>/tunnel-ports.env`.
- **The Info Panel renders the URLs.** Each detected dev server shows up as a row like
  `http://myhost.tail-scale.ts.net:5173  (vite)`. URLs are clickable in modern
  terminals.
- **Tailscale persists across `doey stop`.** You stay connected to the host. Only the
  port watcher stops with the session.

## Prerequisites

- A **Linux remote host** with `sudo` access (the tailscale daemon needs root).
- A **Tailscale account** — free tier is plenty for personal use. Create one at
  [https://tailscale.com](https://tailscale.com).
- **Tailscale installed on your laptop** — download the client at
  [https://tailscale.com/download](https://tailscale.com/download) and sign in with the
  same account you'll use on the remote host.
- `iproute2` on the remote host (provides `ss`). This is installed by default on every
  mainstream Linux distro.

## Setup (one-time, on the remote host)

```bash
doey tunnel setup
```

What happens:

1. Doey checks for the `tailscale` binary. If missing, it prints the official install
   command and asks for confirmation before running
   `curl -fsSL https://tailscale.com/install.sh | sh`. Doey will **not** auto-sudo —
   you accept the prompt and your shell handles the sudo.
2. Doey runs `sudo tailscale up`. On a headless host, tailscaled prints a line like:
   ```
   To authenticate, visit:

       https://login.tailscale.com/a/abc123def456
   ```
   **Click that URL in your laptop browser.** Sign in with your Tailscale account
   and approve the machine. The remote host joins your tailnet immediately.
3. Doey fetches your MagicDNS hostname with `tailscale status --json` (falling back to
   `tailscale ip -4` if `jq` is missing) and prints it:
   ```
   Tunnel hostname: myhost.tail-scale.ts.net
   ```
4. Doey writes `~/.config/doey/tunnel.conf` with your provider choice and hostname.
   That's the only persistent state. Setup is now complete.

## Daily use

```bash
doey tunnel up        # start the port watcher
doey tunnel status    # show provider, hostname, watcher PID, detected URLs
doey tunnel down      # stop the port watcher (tailscale stays up)
```

### Worked example

In one pane:

```bash
cd ~/my-app
pnpm dev
# Vite listens on 127.0.0.1:5173
```

In another pane:

```bash
doey tunnel status
```

Output:

```
  Provider : tailscale
  Hostname : myhost.tail-scale.ts.net
  Watcher  : running (PID 12345)

  Detected dev servers:
    http://myhost.tail-scale.ts.net:5173  (node)
```

Click the URL on your laptop. Vite HMR works exactly as if the dev server were
running locally.

## How port detection works

The watcher polls `ss -tlnp` at a fixed interval (default 2 seconds, override with
`TUNNEL_WATCHER_INTERVAL` in `~/.config/doey/tunnel.conf`).

**Default allowlist** (any listener whose process name matches is included):

```
vite, next, remix, webpack, esbuild, parcel, rollup, turbo, pnpm, npm, yarn,
node, bun, deno, astro, nuxt, svelte, gatsby, rails, puma, python, django,
flask, uvicorn, gunicorn, fastapi, php-fpm, caddy, go, cargo
```

**Default blocklist** (always excluded):

```
sshd, systemd-resolved, dnsmasq, postgres, mysql, redis-server, mongod,
docker-proxy, containerd, dockerd, tailscaled, cloudflared, Xorg, pipewire
```

**Generous fallback:** any `node`, `bun`, or `deno` process listening on ports
3000–9999 is included even if its deeper name doesn't match anything specific.

**Overrides:** set space-separated lists in `~/.config/doey/tunnel.conf`:

```bash
TUNNEL_PORT_ALLOWLIST="3000 5173 8000"      # force-include these ports
TUNNEL_PORT_BLOCKLIST="8080 9090"           # force-exclude these ports
```

## Info Panel integration

When the watcher is running, the Info Panel (window 0, left pane) shows a live
**Tunnels** block with one row per detected port. The panel refreshes on its normal
cycle and re-reads `tunnel-ports.env` each time.

URLs are printed as plain `http://...` strings. Modern terminals auto-detect these
and make them clickable: iTerm2, WezTerm, Kitty, Ghostty, Alacritty, Windows
Terminal, and gnome-terminal all support click-to-open.

## Troubleshooting

**`command not found: tailscale`**
Run `doey tunnel setup` and accept the install prompt. If the install step fails,
fall back to the manual command:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

**No URL printed after `tailscale up`**
The login URL goes to stderr and may be buried in warnings. Run:
```bash
tailscale status
```
If you see `Logged out.`, run `sudo tailscale up` manually and copy the URL.

**Magic-DNS hostname is empty**
MagicDNS is a Tailscale setting, not a per-machine flag. Enable it once at
[https://login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns). After
enabling, re-run `doey tunnel setup` to refresh `~/.config/doey/tunnel.conf`.

**Watcher not detecting my dev server**
First confirm it's listening:
```bash
ss -tlnp | grep :5173
```
If the process name isn't in the allowlist (custom binaries, forks, etc.), force it
via:
```bash
echo 'TUNNEL_PORT_ALLOWLIST="5173"' >> ~/.config/doey/tunnel.conf
doey tunnel down && doey tunnel up
```

**Port watcher won't start**
Check the log:
```bash
cat /tmp/doey/<project>/port-watcher.log
```
Replace `<project>` with your Doey project name — the status output shows the exact
path as the `Runtime` field.

**Already running**
If `doey tunnel up` says `Port watcher already running (PID N)`, that PID is alive.
Run `doey tunnel down` first, then `doey tunnel up` to restart.

## Cleanup

`doey stop` kills the port watcher but deliberately leaves Tailscale connected —
you stay reachable across sessions. To disconnect from your tailnet:

```bash
doey tunnel down      # stop the watcher
sudo tailscale down   # disconnect from the tailnet
```

To uninstall Tailscale entirely:

```bash
sudo apt remove tailscale          # Debian/Ubuntu
sudo dnf remove tailscale          # Fedora/RHEL
sudo pacman -Rns tailscale         # Arch
```

Then remove the Doey config marker:

```bash
rm ~/.config/doey/tunnel.conf
```

## Fallback: cloudflared (no Tailscale account)

If you can't or won't use Tailscale, Doey's existing cloudflared integration still
works. Set the provider manually:

```bash
mkdir -p ~/.config/doey
cat > ~/.config/doey/tunnel.conf <<'EOF'
TUNNEL_PROVIDER=cloudflared
EOF
```

Doey will spawn a cloudflared quick tunnel per detected port. Caveats:

- Each tunnel gets a different random `*.trycloudflare.com` URL — no MagicDNS, no
  stable hostname.
- Quick tunnels have a hard limit of 200 concurrent in-flight requests and no SSE
  support.
- URLs are **public** — anyone with the link can reach your dev server until the
  tunnel closes.

For serious work, Tailscale is the better choice.

## Limitations

- **Linux remote only.** The tailscale install script is Linux-specific. macOS and
  Windows hosts need a manual install (outside the scope of `doey tunnel setup`).
- **Requires sudo on the host.** The tailscale daemon needs `CAP_NET_ADMIN` for the
  tun device.
- **Watcher uses `ss`.** If your system lacks `iproute2`, install it before running
  `doey tunnel up`:
  ```bash
  sudo apt install iproute2
  ```
- **SSH `-L` fallback is not yet shipped.** If both Tailscale and cloudflared are
  unavailable, you currently need to run `ssh -L 5173:localhost:5173 user@host`
  manually from your laptop. A helper is planned for a later phase.
