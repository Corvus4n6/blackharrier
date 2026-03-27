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
# Downloads each script to a staging directory first, then installs atomically
# so a failed or partial download never overwrites an installed file.
BHRAW="https://github.com/Corvus4n6/blackharrier/raw/master/script"
BHTMP=$(mktemp -d)
trap 'rm -rf "${BHTMP}"' EXIT

wget -O "${BHTMP}/bhpwdchk"    "${BHRAW}/bhpwdchk.sh"    || { echo "ERROR: Failed to download bhpwdchk." >&2;    exit 1; }
wget -O "${BHTMP}/bhreplicate" "${BHRAW}/bhreplicate.sh" || { echo "ERROR: Failed to download bhreplicate." >&2; exit 1; }
wget -O "${BHTMP}/bhupdate"    "${BHRAW}/bhupdate.sh"    || { echo "ERROR: Failed to download bhupdate." >&2;    exit 1; }
wget -O "${BHTMP}/bhotg"       "${BHRAW}/bhotg.sh"       || { echo "ERROR: Failed to download bhotg." >&2;       exit 1; }

# all downloads succeeded - install atomically
for SCRIPT in bhpwdchk bhreplicate bhupdate bhotg; do
    mv "${BHTMP}/${SCRIPT}" "/usr/local/sbin/${SCRIPT}"
    chmod +x "/usr/local/sbin/${SCRIPT}"
done
