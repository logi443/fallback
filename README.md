# Fallback

By - Meysam | [github.com/logi443/nginx](https://github.com/logi443/fallback)

Menu-driven local nginx decoy backend for PasarGuard's VLESS TLS fallback.
Unauthenticated connections are reverse-proxied to a real decoy site (e.g. soft98.ir),
so the server looks like an ordinary website to probes.

## Install & run

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/logi443/fallback/main/fallback.sh)"
```

Or download, then run:

```bash
curl -O https://raw.githubusercontent.com/logi443/fallback/main/fallback.sh
sudo bash fallback.sh
```

## Menu

| Option | Action |
|---|---|
| 1 | Install — asks for the fake SNI domain, fallback local port, and PROXY protocol (off / on). |
| 2 | Edit configuration — change any value (0 to go back). |
| 3 | Remove — deletes the fallback config. |
| 4 | Service status / test — nginx state, listening port, and a live curl test. |
| 0 | Exit |

## In the PasarGuard inbound

- TLS fallback **dest**: `127.0.0.1:<fallback port>`
- TLS fallback **PROXY protocol (xver)**: `0` if you chose Off, `1` or `2` if you chose On
- **ALPN**: `http/1.1` (the fallback backend speaks HTTP/1.1 only)

The PROXY-protocol choice in the script and the inbound's xver must match, or the
fallback returns `400`.
