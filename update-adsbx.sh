#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

if [[ "$(id -u)" != "0" ]]; then
    exec sudo bash "$BASH_SOURCE"
fi

# in case /var/log is full ... delete some logs
echo test > /var/log/.test 2>/dev/null || rm -f /var/log/*.log

restartIfEnabled() {
    # check if enabled
    if systemctl is-enabled "$1" &>/dev/null; then
            systemctl restart "$1"
    fi
}

function aptInstall() {
    if ! apt install -y --no-install-recommends --no-install-suggests "$@"; then
        apt update
        apt install -y --no-install-recommends --no-install-suggests "$@"
    fi
}

packages="git make gcc libusb-1.0-0-dev librtlsdr-dev libncurses5-dev zlib1g-dev python3-dev python3-venv"
aptInstall $packages

echo '########################################'
echo 'FULL LOG ........'
echo 'located at /tmp/adsbx_update_log .......'
echo '########################################'
echo '..'

# let's do all of this in a clean directory:
updir=/tmp/update-adsbx
log=/tmp/adsbx_update_log

rm -rf $updir
mkdir -p $updir
cd $updir

rm -f $log

git clone --quiet --depth 1 https://github.com/ADSBexchange/adsbx-update.git
cd adsbx-update

find skeleton -type d | cut -d / -f1 --complement | grep -v '^skeleton' | xargs -t -I '{}' -s 2048 mkdir -p /'{}'
find skeleton -type f | cut -d / -f1 --complement | xargs -I '{}' -s 2048 cp -T --remove-destination -v skeleton/'{}' /'{}'

systemctl daemon-reload

# enable services
systemctl enable \
    adsbexchange-first-run.service \
    adsbx-zt-enable.service \
    readsb.service \
    adsbexchange-mlat.service \
    adsbexchange-feed.service

cd $updir
git clone --quiet --depth 1 https://github.com/adsbxchange/readsb.git >> $log

echo 'compiling readsb (this can take a while) .......'

cd readsb

if dpkg --print-architecture | grep -qs armhf; then
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-mcpu=arm1176jzf-s -mfpu=vfp"  >> $log
else
    make -j3 AIRCRAFT_HASH_BITS=14 RTLSDR=yes OPTIMIZE=""  >> $log
fi

echo 'copying new readsb binaries ......'
cp -f readsb /usr/bin/adsbxfeeder
cp -f readsb /usr/bin/adsbx-978
cp -f readsb /usr/bin/readsb
cp -f viewadsb /usr/bin/viewadsb


echo 'make sure unprivileged users exist (readsb / adsbexchange) ......'
for USER in adsbexchange readsb; do
    if ! id -u "${USER}" &>/dev/null
    then
        adduser --system --home "/usr/local/share/$USER" --no-create-home --quiet "$USER"
    fi
done

# plugdev required for bladeRF USB access
adduser readsb plugdev
# dialout required for Mode-S Beast and GNS5894 ttyAMA0 access
adduser readsb dialout

echo 'restarting services .......'
restartIfEnabled readsb
restartIfEnabled adsbexchange-feed
restartIfEnabled adsbexchange-978

cd $updir
rm -rf $updir/readsb

echo 'updating adsbx stats .......'
wget --quiet -O /tmp/axstats.sh https://raw.githubusercontent.com/adsbxchange/adsbexchange-stats/master/stats.sh >> $log
bash /tmp/axstats.sh >> $log

echo 'cleaming up stats /tmp .......'
rm -f /tmp/axstats.sh
rm -f -R /tmp/adsbexchange-stats-git

echo 'creating python virtual environment for mlat-client .......'
VENV=/usr/local/share/adsbexchange/venv/
if [[ -f /usr/local/share/adsbexchange/venv/bin/python3.7 ]] && command -v python3.9 &>/dev/null;
then
    rm -rf "$VENV"
fi
/usr/bin/python3 -m venv "$VENV"

cd $updir
echo 'cloning to mlat-client .......'
git clone --quiet --depth 1 --single-branch https://github.com/adsbxchange/mlat-client.git >> $log

echo 'building and installing mlat-client to virtual-environment .......'
cd mlat-client
source /usr/local/share/adsbexchange/venv/bin/activate >> $log
python3 setup.py build >> $log
python3 setup.py install >> $log

echo 'starting services .......'
restartIfEnabled adsbexchange-mlat

cd $updir
rm -f -R $updir/mlat-client

echo 'update uat ...'

cd $updir
git clone https://github.com/adsbxchange/uat2esnt.git >> $log
cd uat2esnt
make uat2esnt >> $log
cp -T -f uat2esnt /usr/local/bin/uat2esnt

cd $updir
rm -f -R $updir/uat2esnt

echo 'restart uat services .......'
restartIfEnabled adsbexchange-978-convert

echo 'update tar1090 ...........'
bash -c "$(wget -nv -O - https://raw.githubusercontent.com/wiedehopf/tar1090/master/install.sh)"  >> $log


# the following doesn't apply for chroot (image creation)
if ischroot; then
    exit 0
fi

echo "#####################################"
cat /boot/adsbx-uuid
echo "#####################################"
sed -e 's$^$https://www.adsbexchange.com/api/feeders/?feed=$' /boot/adsbx-uuid
echo "#####################################"

echo '--------------------------------------------'
echo '--------------------------------------------'
echo '             UPDATE COMPLETE'
echo "      FULL LOG:  $log"
echo '--------------------------------------------'
echo '--------------------------------------------'


cd /tmp
rm -rf $updir
