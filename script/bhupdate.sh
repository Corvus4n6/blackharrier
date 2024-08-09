#!/bin/bash
# BlackHarrier11 Updater script

# Designed to handle the updating of all the things beyond apt-get update

# Die on error
set -e

# update the repo based stuff

apt-get update
#apt-get -y upgrade
apt-get -y full-upgrade
apt-get -y autoremove
apt-get clean

# update the BH11 Scripts
# TODO - add checks to scripts and sources
wget -O /usr/local/sbin/bhpwdchk https://github.com/Corvus4n6/blackharrier/raw/master/script/bhpwdchk.sh
chmod +x /usr/local/sbin/bhpwdchk
wget -O /usr/local/sbin/bhreplicate https://github.com/Corvus4n6/blackharrier/raw/master/script/bhreplicate.sh
chmod +x /usr/local/sbin/bhreplicate
wget -O /usr/local/sbin/bhupdate https://github.com/Corvus4n6/blackharrier/raw/master/script/bhupdate.sh
chmod +x /usr/local/sbin/bhupdate
wget -O /usr/local/sbin/bhotg https://github.com/Corvus4n6/blackharrier/raw/master/script/bhotg.sh
chmod +x /usr/local/sbin/bhotg
