
:local containerAddr "10.0.20.5/32"

/user group add name=certbot policy=ssh,ftp,read,write,sensitive \
    comment="certbot-multidevice: certificate deployment"

/user add name=certbot group=certbot address=$containerAddr \
    password=[:rndstr length=32] \
    comment="certbot-multidevice container (key auth only)"

/user ssh-keys import public-key-file=certbot.pub user=certbot
/file remove [find where name="certbot.pub"]
