ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim
FROM ${RUNTIME_BASE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      certbot python3-certbot-dns-route53 openssh-client \
      ca-certificates bash openssl && \
    rm -rf /var/lib/apt/lists/*

COPY deploy.rsc.template /usr/local/share/certbot-multidevice/
COPY certbot-multidevice.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/certbot-multidevice.sh

CMD ["/usr/local/bin/certbot-multidevice.sh"]
