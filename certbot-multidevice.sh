#!/bin/bash
set -u

DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-}"
SSH_USER="${SSH_USER:-certbot}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/ssh/id_ed25519}"
SERVICES="${SERVICES:-www-ssl api-ssl}"
STAGING="${STAGING:-N}"
FORCE_DEPLOY="${FORCE_DEPLOY:-N}"
RENEW_INTERVAL_SECONDS="${RENEW_INTERVAL_SECONDS:-43200}"
RETRY_INTERVAL_SECONDS="${RETRY_INTERVAL_SECONDS:-1800}"
RUN_ONCE="${RUN_ONCE:-N}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

LE_DIR=/etc/letsencrypt
STATE_DIR="${LE_DIR}/multidevice"
KNOWN_HOSTS="${STATE_DIR}/known_hosts"
SSH_KEY=/root/.ssh/id_deploy
RSC_TEMPLATE=/usr/local/share/certbot-multidevice/deploy.rsc.template

log()   { printf '%s certbot-multidevice: %s\n' "$(date -u +%FT%TZ)" "$*"; }
fatal() { log "FATAL: $*" >&2; exit 1; }

[ -n "${DOMAIN_SUFFIX}" ]           || fatal "DOMAIN_SUFFIX is required (e.g. example.com)."
[ -n "${DEVICES:-}" ]               || fatal "DEVICES is required (FQDNs, e.g. router.${DOMAIN_SUFFIX})."
[ -n "${LE_EMAIL:-}" ]              || fatal "LE_EMAIL is required."
[ -n "${AWS_ACCESS_KEY_ID:-}" ]     || fatal "AWS_ACCESS_KEY_ID is required."
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fatal "AWS_SECRET_ACCESS_KEY is required."
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
[[ "$DOMAIN_SUFFIX" =~ ^${label}(\.${label})+$ ]] || fatal "DOMAIN_SUFFIX '${DOMAIN_SUFFIX}' is not a valid domain."
[[ "$SSH_USER" =~ ^[a-z0-9_-]+$ ]]                || fatal "SSH_USER '${SSH_USER}' contains invalid characters."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]]                     || fatal "SSH_PORT must be numeric."
[[ "$RENEW_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]       || fatal "RENEW_INTERVAL_SECONDS must be numeric."
[[ "$RETRY_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]       || fatal "RETRY_INTERVAL_SECONDS must be numeric."

read -r -a service_list <<< "${SERVICES//,/ }"
[ "${#service_list[@]}" -gt 0 ] || fatal "SERVICES is empty."
for s in "${service_list[@]}"; do
  [[ "$s" =~ ^[a-z0-9-]+$ ]] || fatal "SERVICES entry '${s}' contains invalid characters."
done

read -r -a raw_devices <<< "${DEVICES//,/ }"
devices=()
for d in "${raw_devices[@]}"; do
  d="${d,,}"
  [[ "$d" =~ ^${label}(\.${label})+$ ]] || fatal "DEVICES entry '${d}' is not a valid hostname."
  [[ "$d" == *".${DOMAIN_SUFFIX}" ]]    || fatal "DEVICES entry '${d}' is not inside ${DOMAIN_SUFFIX}."
  devices+=("$d")
done
[ "${#devices[@]}" -gt 0 ] || fatal "DEVICES contains no hostnames."

[ -r "$SSH_KEY_FILE" ]  || fatal "SSH private key not readable at ${SSH_KEY_FILE} (mount it read-only)."
[ -r "$RSC_TEMPLATE" ]  || fatal "RouterOS script template missing at ${RSC_TEMPLATE}."

install -d -m 700 /root/.ssh
install -m 600 "$SSH_KEY_FILE" "$SSH_KEY"
[ "$(stat -c %a "$SSH_KEY")" = 600 ] || fatal "SSH key ${SSH_KEY} is not mode 600."
install -d -m 700 "$STATE_DIR" "${STATE_DIR}/deployed"

COMMON_OPTS=(-i "$SSH_KEY"
             -o BatchMode=yes -o IdentitiesOnly=yes
             -o StrictHostKeyChecking=accept-new
             -o "UserKnownHostsFile=${KNOWN_HOSTS}"
             -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

dev_ssh() { timeout 180 ssh "${COMMON_OPTS[@]}" -p "$SSH_PORT" "$@"; }
dev_scp() { timeout 180 scp "${COMMON_OPTS[@]}" -P "$SSH_PORT" "$@"; }

cert_name_for() {
  if [ "$STAGING" = "Y" ]; then echo "$1.staging"; else echo "$1"; fi
}

obtain_cert() {
  local fqdn="$1" cert_name="$2"
  local args=(certonly --dns-route53 --non-interactive --agree-tos
              -m "$LE_EMAIL" --cert-name "$cert_name" -d "$fqdn"
              --keep-until-expiring)
  [ "$STAGING" = "Y" ] && args+=(--staging)
  certbot "${args[@]}"
}

deploy_cert() {
  local fqdn="$1" cert_name="$2"
  local live="${LE_DIR}/live/${cert_name}"
  local fullchain="${live}/fullchain.pem" privkey="${live}/privkey.pem"
  local marker="${STATE_DIR}/deployed/${fqdn}"

  [ -r "$fullchain" ] && [ -r "$privkey" ] || { log "${fqdn}: no certificate files in ${live}"; return 1; }

  local fp; fp="$(sha256sum "$fullchain" | cut -d' ' -f1)"
  if [ "$FORCE_DEPLOY" != "Y" ] && [ "$(cat "$marker" 2>/dev/null)" = "$fp" ]; then
    log "${fqdn}: device already has the current certificate (expires $(openssl x509 -enddate -noout -in "$fullchain" | cut -d= -f2))."
    return 0
  fi

  local tag; tag="le-$(date -u +%Y%m%d%H%M%S)"
  local work; work="$(mktemp -d)"
  local svc_array="" s
  for s in "${service_list[@]}"; do svc_array+="\"${s}\";"; done
  sed -e "s/@TAG@/${tag}/g" -e "s/@SERVICES@/{${svc_array%;}}/g" \
      "$RSC_TEMPLATE" > "${work}/deploy.rsc"

  local target="${SSH_USER}@${fqdn}" out rc=1
  log "${fqdn}: deploying certificate as '${tag}'..."
  if dev_scp "$fullchain" "${target}:${tag}-fullchain.pem" \
     && dev_scp "$privkey"   "${target}:${tag}-privkey.pem" \
     && dev_scp "${work}/deploy.rsc" "${target}:${tag}-deploy.rsc"; then
    out="$(dev_ssh "$target" "/import file-name=${tag}-deploy.rsc" 2>&1)"
    if grep -q "CERTBOT_DEPLOY_OK ${tag}" <<< "$out"; then
      rc=0
      printf '%s' "$fp" > "$marker"
      log "${fqdn}: deployed (services: ${service_list[*]})."
    else
      log "${fqdn}: device-side import did not report success. Output:" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
    fi
  else
    log "${fqdn}: upload failed (key not authorised, user/policy missing, host key changed, or host unreachable)." >&2
  fi

  dev_ssh "$target" "/file remove [find where name~\"^${tag}-\"]" >/dev/null 2>&1 || \
    log "${fqdn}: WARNING could not remove uploaded '${tag}-*' files from the device." >&2
  rm -rf "$work"
  return "$rc"
}

process_device() {
  local fqdn="$1" cert_name; cert_name="$(cert_name_for "$fqdn")"

  if ! getent hosts "$fqdn" >/dev/null; then
    log "${fqdn}: does not resolve in DNS — skipping." >&2
    return 1
  fi

  if ! obtain_cert "$fqdn" "$cert_name"; then
    if [ -f "${LE_DIR}/live/${cert_name}/fullchain.pem" ]; then
      log "${fqdn}: certbot failed but an existing certificate is present — continuing." >&2
    else
      log "${fqdn}: certbot failed and there is no certificate." >&2
      return 1
    fi
  fi
  deploy_cert "$fqdn" "$cert_name"
}

run_cycle() {
  local failed=0 d
  for d in "${devices[@]}"; do
    process_device "$d" || { failed=$((failed + 1)); log "${d}: FAILED"; }
  done
  log "cycle complete: $(( ${#devices[@]} - failed ))/${#devices[@]} devices OK."
  return "$failed"
}

trap 'log "terminating."; exit 0' TERM INT

log "starting: ${#devices[@]} device(s): ${devices[*]} (staging=${STAGING})"
while true; do
  run_cycle; failed=$?
  if [ "$RUN_ONCE" = "Y" ]; then
    [ "$failed" -eq 0 ] && exit 0 || exit 1
  fi
  if [ "$failed" -gt 0 ]; then wait_for="$RETRY_INTERVAL_SECONDS"; else wait_for="$RENEW_INTERVAL_SECONDS"; fi
  log "sleeping ${wait_for}s."
  sleep "$wait_for" & wait $!
done
