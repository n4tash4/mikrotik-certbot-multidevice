# mikrotik-certbot-multidevice

A [RouterOS container](https://help.mikrotik.com/docs/display/ROS/Container) that keeps a Let's Encrypt certificate on each of your MikroTik devices. It runs on one MikroTik router and deploys to every device you list, including itself.

For each device in `DEVICES`, the container runs this sequence:

1. Run `certbot certonly --dns-route53` with a separate lineage per device. certbot does nothing until the certificate is within 30 days of expiry.
2. If the certificate differs from the last one deployed, upload `fullchain.pem`, `privkey.pem`, and a generated RouterOS script to the device with `scp`, as the user `certbot`.
3. Run `/import` on that script. The script imports the certificate and key, sets them on the SSL services, and removes older `le-*` certificates.
4. Record the deployed fingerprint, then delete the uploaded files, including the private key, from the device.

The loop runs every 12 hours, or 30 minutes after a failure.
The container has no SSH server. It is an SSH client of the devices.

The examples use a container on `10.0.20.5` and devices under `example.com`.
Replace them with your own values.

## Requirements

- RouterOS 7.6 or later with the `container` package, and container mode enabled.
- An ext4 disk mounted at `/storage`.
- A bridge named `bridge-containers` on the router, or an edit to `rsc/01-router-certbot.rsc` for your own bridge.
- A Route 53 hosted zone for `DOMAIN_SUFFIX`, and an IAM user with the policy below.
- A DNS name for each device that resolves from inside the container.
- To build: Docker with Buildx, and `skopeo`.

### IAM policy

certbot's Route 53 plugin needs this policy. Replace `<HOSTED_ZONE_ID>` with the ID of your zone.

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": ["route53:ListHostedZones", "route53:GetChange"],
			"Resource": "*"
		},
		{
			"Effect": "Allow",
			"Action": "route53:ChangeResourceRecordSets",
			"Resource": "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
		}
	]
}
```

## Build

```sh
./build.sh
```

The script writes `certbot-multidevice-arm64.tar`. The image is arm64 only.

## Paths on the router

| Path | Purpose |
|---|---|
| `/storage/certbot-multidevice-arm64.tar` | Image file. |
| `/storage/containers/certbot` | Container root-dir. RouterOS deletes it when you remove the container. |
| `/storage/container-data/certbot/letsencrypt` | Mounted read-write at `/etc/letsencrypt`. Holds certificates, the ACME account, the deployed state, and the pinned device host keys. |
| `/storage/container-data/certbot/ssh` | Mounted read-only at `/ssh`. Holds `id_ed25519`, the private key that logs in to the devices. |

If `/etc/letsencrypt` doesn't persist, every restart requests every certificate again and you hit Let's Encrypt rate limits.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DOMAIN_SUFFIX` | Yes | | Every device name must end in this, for example `example.com`. |
| `DEVICES` | Yes | | Device names, separated by spaces or commas, for example `router.example.com ap1.example.com`. Each name is also the SSH target. |
| `LE_EMAIL` | Yes | | Let's Encrypt account email. Keep it in `rsc/secrets.local.rsc`. |
| `AWS_ACCESS_KEY_ID` | Yes | | IAM access key ID for `certbot-dns-route53`. Keep it in `rsc/secrets.local.rsc`. |
| `AWS_SECRET_ACCESS_KEY` | Yes | | IAM secret access key. Keep it in `rsc/secrets.local.rsc`. |
| `AWS_DEFAULT_REGION` | No | `us-east-1` | AWS region for API calls. |
| `SSH_USER` | No | `certbot` | RouterOS user on each device. |
| `SSH_PORT` | No | `22` | SSH port on each device. |
| `SSH_KEY_FILE` | No | `/ssh/id_ed25519` | Path of the private key inside the container. |
| `SERVICES` | No | `www-ssl api-ssl` | `/ip service` entries that get the certificate. Separate entries with spaces or commas. |
| `STAGING` | No | `N` | `Y` uses the Let's Encrypt staging CA. Staging has its own lineage. |
| `FORCE_DEPLOY` | No | `N` | `Y` deploys again even if the certificate has not changed. |
| `RENEW_INTERVAL_SECONDS` | No | `43200` | Time between passes. |
| `RETRY_INTERVAL_SECONDS` | No | `1800` | Time to the next pass after a device fails. |
| `RUN_ONCE` | No | `N` | `Y` runs one pass and exits. The exit code is non-zero if any device failed. |

The script validates the configuration at start and exits with an error if a check fails.
`DOMAIN_SUFFIX` must be a lowercase domain with at least two labels. The script lowercases each `DEVICES` entry. Each entry must be a host name with at least two labels that ends in `.` followed by `DOMAIN_SUFFIX`. `SSH_USER` may contain only `a-z`, `0-9`, `_`, and `-`. Each `SERVICES` entry may contain only `a-z`, `0-9`, and `-`. `SSH_PORT` and both interval variables must be numbers.

## Deploy

1. Create a key pair. Git ignores `secrets/`.

	```sh
	mkdir -p secrets
	ssh-keygen -t ed25519 -N '' -C certbot-multidevice -f secrets/id_ed25519
	```

2. On each device, upload the public key and import `rsc/00-device-certbot-user.rsc`.
	Before you upload the script, set `containerAddr` in it to the container address, so the user can log in only from the container.
	The script creates the `certbot` group and user, with key login only. The group has the `ssh`, `ftp`, `read`, `write`, and `sensitive` policies. `scp` needs `ftp`, and the certificate import needs `write` and `sensitive`.

	```sh
	scp -O secrets/id_ed25519.pub admin@<device>:certbot.pub
	scp -O rsc/00-device-certbot-user.rsc admin@<device>:
	ssh admin@<device> '/import file-name=00-device-certbot-user.rsc'
	```

3. On each device, enable `www-ssl` and `api-ssl`. The container sets their certificate but doesn't enable them.
4. Upload the image and the private key to the router.

	```sh
	scp -O certbot-multidevice-arm64.tar admin@<router>:storage/
	scp -O secrets/id_ed25519 admin@<router>:storage/container-data/certbot/ssh/id_ed25519
	```

5. Copy `rsc/secrets.example.rsc` to `rsc/secrets.local.rsc` and fill it in. Git ignores `rsc/secrets.local.rsc`.
6. In `rsc/01-router-certbot.rsc`, set `DOMAIN_SUFFIX`, `DEVICES`, and the addresses for your network.
7. On the router, import `rsc/secrets.local.rsc`, then `rsc/01-router-certbot.rsc`. Delete `secrets.local.rsc` from the router afterwards.
8. Start the container. The example script sets `STAGING=Y`, so the first deployment uses staging certificates.
9. When the staging certificates deploy, remove the `STAGING` entry from the `certbot` env list, then remove and add the container again. RouterOS reads the env list only when you add the container.

## Verify

1. On the router, read the container log. `logging=yes` sends it to the router log.

	```
	/log print where message~"certbot-multidevice"
	```

2. Look for `deployed (services: www-ssl api-ssl)` for each device, and `cycle complete: N/N devices OK`.
3. On a device, check that a certificate named `le-<timestamp>` exists and that the services use it.

	```
	/certificate print where name~"^le-"
	/ip service print detail where name~"ssl"
	```

To test one pass without waiting, set `RUN_ONCE=Y` and add the container again. The container exits when the pass ends.

## Upgrade

If other containers on the router use the same Debian base, stop all of them before you add the new image.
When a container that shares a layer is running, extraction fails with `Text file busy`.

1. Upload the new tar.
2. Stop every container with `/container stop [find]`.
3. Remove the certbot container.
4. Add it again with the same settings. Wait until its status is `stopped`.
5. Start all containers.

## Remove

1. Stop the container with `/container stop [find where comment="certbot-multidevice"]`.
2. Remove the container with `/container remove [find where comment="certbot-multidevice"]`.
3. Remove the env list, the mount list, the veth, and its bridge port.
4. Delete `/storage/container-data/certbot` to discard the certificates, the ACME account, and the private key.
5. On each device, remove the `certbot` user and group, and the `le-*` certificates.

## Notes

- The container pins each device's SSH host key on the first connection and checks it on later connections. If you reset a device, delete its line from `/etc/letsencrypt/multidevice/known_hosts` with `/container/shell`.
- The container owns every certificate whose name starts with `le-`. It deletes any `le-*` certificate on the device that is not the current one.
- The `certbot` user has the `ssh`, `ftp`, `read`, `write`, and `sensitive` policies. Anyone with the private key can change the device configuration, so keep `secrets/` private.
