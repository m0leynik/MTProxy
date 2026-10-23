# MTProxy
Simple MT-Proto proxy

## Building
Install dependencies, you would need common set of tools for building from source, and development packages for `openssl` and `zlib`.

On Debian/Ubuntu:
```bash
apt install git curl build-essential libssl-dev zlib1g-dev
```
On CentOS/RHEL:
```bash
yum install openssl-devel zlib-devel
yum groupinstall "Development Tools"
```

Clone the repo:
```bash
git clone https://github.com/TelegramMessenger/MTProxy
cd MTProxy
```

To build, simply run `make`, the binary will be in `objs/bin/mtproto-proxy`:

```bash
make && cd objs/bin
```

If the build has failed, you should run `make clean` before building it again.

## Running
1. Obtain a secret, used to connect to telegram servers.
```bash
curl -s https://core.telegram.org/getProxySecret -o proxy-secret
```
2. Obtain current telegram configuration. It can change (occasionally), so we encourage you to update it once per day.
```bash
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
```
3. Generate a secret to be used by users to connect to your proxy.
```bash
head -c 16 /dev/urandom | xxd -ps
```
4. Run `mtproto-proxy`:
```bash
./mtproto-proxy -u nobody -p 8888 -H 443 -S <secret> --aes-pwd proxy-secret proxy-multi.conf -M 1
```
... where:
- `nobody` is the username. `mtproto-proxy` calls `setuid()` to drop privileges.
- `443` is the port, used by clients to connect to the proxy.
- `8888` is the local port. You can use it to get statistics from `mtproto-proxy`. Like `wget localhost:8888/stats`. You can only get this stat via loopback.
- `<secret>` is the secret generated at step 3. Also you can set multiple secrets: `-S <secret1> -S <secret2>`.
- `proxy-secret` and `proxy-multi.conf` are obtained at steps 1 and 2.
- `1` is the number of workers. You can increase the number of workers, if you have a powerful server.

Also feel free to check out other options using `mtproto-proxy --help`.

5. Generate the link with following schema: `tg://proxy?server=SERVER_NAME&port=PORT&secret=SECRET` (or let the official bot generate it for you).
6. Register your proxy with [@MTProxybot](https://t.me/MTProxybot) on Telegram.
7. Set received tag with arguments: `-P <proxy tag>`
8. Enjoy.

## Random padding
Due to some ISPs detecting MTProxy by packet sizes, random padding is
added to packets if such mode is enabled.

It's only enabled for clients which request it.

Add `dd` prefix to secret (`cafe...babe` => `ddcafe...babe`) to enable
this mode on client side.

## Systemd example configuration
1. Create systemd service file (it's standard path for the most Linux distros, but you should check it before):
```bash
nano /etc/systemd/system/MTProxy.service
```
2. Edit this basic service (especially paths and params):
```bash
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/MTProxy
ExecStart=/opt/MTProxy/mtproto-proxy -u nobody -p 8888 -H 443 -S <secret> -P <proxy tag> <other params>
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
3. Reload daemons:
```bash
systemctl daemon-reload
```
4. Test fresh MTProxy service:
```bash
systemctl restart MTProxy.service
# Check status, it should be active
systemctl status MTProxy.service
```
5. Enable it, to autostart service after reboot:
```bash
systemctl enable MTProxy.service
```

## Docker
Telegram is also providing [official Docker image](https://hub.docker.com/r/telegrammessenger/proxy/).
Note: the image is outdated. To run *this* source tree in Docker, use the `Dockerfile` in the repo.

### Build and run
```bash
docker build -t mtproxy .
docker run -d --name mtproxy --restart unless-stopped -p 443:443 \
  -e SECRET=$(head -c 16 /dev/urandom | xxd -ps) \
  -e TAG="<proxy tag>" \
  mtproxy
```

The container downloads `proxy-secret` and `proxy-multi.conf` on every start.
Since the DC config changes occasionally, restart the container once per day
(or use the systemd timer below). The client secret is passed via the `SECRET`
environment variable and stays unchanged across restarts.

### Fake-TLS ("ee") mode
To make the proxy look like ordinary TLS traffic to a given domain, pass a
domain. The server then runs in TLS-transport mode, and clients use the `ee`
secret form: `ee<secret><hex(domain)>`.

```bash
sudo docker/install-systemd.sh --domain example.com
```

The installer prints the ready-to-use `ee…` secret and `tg://` link. For a
plain `docker run`, add `-e DOMAIN=example.com`. Only TLS transport is served
in this mode, and a single worker (`--workers 1`) is recommended.

### Run as a systemd service
`docker/install-systemd.sh` builds the image, generates a client secret (stored
in `/etc/mtproxy.env`, kept across restarts and installer re-runs) and installs:

- `MTProxy.service` — runs the Docker container;
- `MTProxy-reload.timer` — restarts the service daily at 04:00 to refresh
  `proxy-multi.conf` (the binary cannot reload it while running).

```bash
sudo docker/install-systemd.sh
systemctl status MTProxy
systemctl list-timers MTProxy-reload.timer
```

To change settings later, edit `/etc/mtproxy.env` and run `systemctl restart
MTProxy`. See `docker/install-systemd.sh --help` for all options (secret, tag,
`--domain`, ports, workers, `--uninstall`, ...).
