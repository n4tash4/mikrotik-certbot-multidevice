/interface/veth/add name=veth-certbot address=10.0.20.5/24 gateway=10.0.20.1 \
    comment="certbot-multidevice container"
/interface/bridge/port/add bridge=bridge-containers interface=veth-certbot

/container/envs/add list=certbot key="DOMAIN_SUFFIX"      value="example.com"
/container/envs/add list=certbot key="DEVICES"            value="router.example.com switch1.example.com ap1.example.com"
/container/envs/add list=certbot key="AWS_DEFAULT_REGION" value="us-east-1"
/container/envs/add list=certbot key="STAGING"            value="Y"

/container/mounts/add list=certbot src=/storage/container-data/certbot/letsencrypt dst=/etc/letsencrypt mode=rw
/container/mounts/add list=certbot src=/storage/container-data/certbot/ssh         dst=/ssh             mode=ro

/container/add file=storage/certbot-multidevice-arm64.tar interface=veth-certbot \
    envlists=certbot mountlists=certbot hostname=certbot-multidevice \
    dns=10.0.20.1 root-dir=/storage/containers/certbot \
    cmd=/usr/local/bin/certbot-multidevice.sh start-on-boot=yes logging=yes stop-time=10s \
    comment="certbot-multidevice"
