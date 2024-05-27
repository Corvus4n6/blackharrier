#!/bin/bash

# die on error - add -x under dev to monitor the script
set -e

# make sure we are running as root
if [[ ${EUID} -ne 0 ]]; then
   echo "This setup script must be run as root"
   exit 1
fi

# set architecture var
ARCHITECTURE=`uname -m`

if [ ${ARCHITECTURE} != 'x86_64' ]; then
  echo "This setup script will only work on x86_64 architecture."
  exit 1
fi

# figure out who is logged in to the console (assuming they are the primary user
MAINUSER=`who | grep '(:0)' | awk '{print $1}'`
# confirm with the user that this will be the primary user of the system
printf "Enter the name of the primary user for this install [${MAINUSER}]: "
read TMPUSER
if [ "${TMPUSER}" == "" ]; then
	echo Default user set to ${MAINUSER}
else
	# checking to make sure this is a real user
	if [ `id -u "${TMPUSER}"` ]; then
		echo Setting default user to ${TMPUSER}
		MAINUSER="${TMPUSER}"
	else
		echo Cannot set default user to ${TMPUSER}
		exit 1
	fi
fi

# workstation mode?
printf "Workstation mode? Allows access to hardware clock and will not delete user"
printf "passwords. Portable mode is default. [y/N]: "
read TMPMODE
if [ "${TMPMODE}" == "" ] || [ "${TMPMODE}" == "n" ]  || [ "${TMPMODE}" == "N" ]; then
	echo Continuing in portable mode.
	SETUPMODE="portable"
else
	echo Continuing in workstation mode.
	SETUPMODE="workstation"
  # TODO - disable automatic login (if set) on workstation mode and provide easy swtich / instructions to disable in protable mode
fi

# pre-cleaning
apt purge -y hypnotix hexchat mintwelcome evolution-data-server evolution-data-server-common
apt autoremove -y

# stripping out old kernels and saving space
LATESTKERN=`uname -r | grep -o -E '[0-9][0-9\.\-]+[0-9]'`
echo Latest kernel version is: ${LATESTKERN}
OLDKERNLIST=`dpkg --list | awk '{print $2}' - | grep 'linux-image-' | grep -v ${LATESTKERN} | grep -o -E '[0-9][0-9\.\-]+[0-9]' | sort -u | tr '\n' '|' | sed s/\|$//`
if [ ${OLDKERNLIST} ]; then
    REMOVELIST=`dpkg --list | awk '{print $2}' - | grep -E "${OLDKERNLIST}" | tr '\n' ' '`
    echo "Found the following old kernel bits:"
    echo ${REMOVELIST} | tr ' ' '\n' | column
    # Removing the ask
    #printf "Remove the above packages? [y/n] "
    #read KILLKERNS
    KILLKERNS="y"
fi

if [ "${KILLKERNS}" == "y" ]  || [ "${KILLKERNS}" == "Y" ]; then
	apt purge -y ${REMOVELIST}
fi

# add fdisk - not default in ubuntu 23.10
# resolvconf needed for networking and wireguard
apt install -y fdisk resolvconf

# need to differentiate between EFI and MBR modes
# determine what kind of partition structure this is and react accordingly - failed on encrypted mapper path
# fix below assumes only one disk is present
#SOURCEMEDIA=`findmnt -M / -n -o SOURCE | sed -e 's/.$//'`
#SOURCELABEL=`parted -s ${SOURCEMEDIA} -- print | grep 'Partition Table:' | grep -o -E '...$'`
SOURCELABEL=`fdisk -l | grep 'Disklabel type: ' | grep -o -E '...$'`
if [[ ${SOURCELABEL} == "gpt" ]]; then
	echo "Building GPT/EFI system"
	MODE="EFI"
elif [[ ${SOURCELABEL} == "dos" ]]; then
	echo "Switching to MBR build"
	MODE="MBR"
else
	echo "Unexpected disk label."
	read -p "Perform network-based build or something? [y/n] " choice
	# TODO add option to force something
	case ${choice} in
		y) exec bhreplicateinet ${1} ;;
		Y) exec bhreplicateinet ${1} ;;
		*) exit 1
	esac
	# TODO - write it
	MODE="NET"
  echo Sorry, this feature has not been written yet. Exiting.
  exit 1
fi

# First - check all the links before running - failures will stop this script so we can fix it
# wget --spider -nv https://url
echo "Checking all dependency URLs ..."
wget --spider -nv https://github.com/FreddieWitherden/libforensic1394.git
wget --spider -nv https://github.com/simsong/bulk_extractor.git
wget --spider -nv https://packages.sits.lu/foss/debian/packages.sits.lu.list
wget --spider -nv https://packages.sits.lu/foss/debian/packages-sits-lu.gpg
wget --spider -nv http://www.webmin.com/download/deb/webmin-current.deb
wget --spider -nv https://github.com/neutrinolabs/xrdp/releases/download/v0.10.0/xrdp-0.10.0.tar.gz
wget --spider -nv https://downloads.volatilityfoundation.org/volatility3/symbols/windows.zip
wget --spider -nv https://downloads.volatilityfoundation.org/volatility3/symbols/mac.zip
wget --spider -nv https://downloads.volatilityfoundation.org/volatility3/symbols/linux.zip
wget --spider -nv https://github.com/veracrypt/VeraCrypt/releases/download/VeraCrypt_1.26.7/veracrypt-1.26.7-Ubuntu-22.04-amd64.deb

echo "All external content is reachable. Installing..."

# set time to UTC
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo UTC > /etc/timezone

# https://www.pinguin.lu/
wget -nH -P /etc/apt/sources.list.d/ https://packages.sits.lu/foss/debian/packages.sits.lu.list
wget -nH -P /usr/share/keyrings/ https://packages.sits.lu/foss/debian/packages-sits-lu.gpg

apt update

# allow sudo without password for default user
echo "${MAINUSER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Make more loop devices - often 8 is not enough
sed -i -e s/'loop'/'loop max_loop=16'/ /etc/modules

if [ ${SETUPMODE} == "portable" ]; then
  echo Disabling hardware clock access in portable mode.
	echo 'HWCLOCKACCESS=no' >> /etc/default/hwclock
else
    # add tools to set the clock in workstation mode
    apt install -y ntpsec-ntpdate
fi

# clean up software we don't need - mostly checking at this point
apt autoremove -y

# disable screensaver since we will have no passwords for users in live, portable mode and they would be very stuck
if [ ${SETUPMODE} == "portable" ]; then
  sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver lock-enabled false
  sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver idle-activation-enabled false
fi

# preconfigure settings in the configdb
apt install -y debconf debconf-utils
# preconfigure some settings - wireshark, mdadm, postfix
debconf-set-selections config/debconf.txt

# build apt install list of everything we need
# FYI - about a 2MB limit on this string
PKGLIST="" #init var
PKGLIST+="default-jdk default-jre default-jre-headless "
PKGLIST+="gdebi gparted btrfs-progs hfsprogs hfsutils hfsplus jfsutils lvm2 nilfs-tools reiser4progs reiserfsprogs xfsprogs xfsdump sshfs exfat-fuse "
PKGLIST+="zfs-initramfs zfs-zed zfsutils-linux "
PKGLIST+="cryptsetup cryptmount f2fs-tools dc3dd dcfldd gddrescue secure-delete extundelete cmake "
PKGLIST+="zerofree "
PKGLIST+="g++ mozo flex libssl-dev lua-rex-tre lua-rex-tre-dev afflib-tools libsqlite3-0 libxml2-dev libsqlite3-dev libtre-dev gnome-disk-utility "
# libyal/libewf dependencies
PKGLIST+="git autoconf automake autopoint libtool pkg-config flex bison "
PKGLIST+="gtkhash vlc brasero sqlitebrowser ghex netdiscover wireshark tshark gnome-nettool nmap mdbtools "
PKGLIST+="ethtool "
PKGLIST+="pv "
# visually compare files
PKGLIST+="forensics-colorize "
#nvme for getting make/model/serial on ssd's on surfaces and probably other devices
PKGLIST+="nvme-cli "
PKGLIST+="gucharmap grub-rescue-pc xorriso scalpel foremost tcpxtract ext4magic xmount testdisk meld xdeview hfsutils-tcltk "
PKGLIST+="yara galleta pasco vinetto rifiuti2 vim mdadm screen python3-setuptools intltool lime-forensics-dkms dmraid "
PKGLIST+="git gpart iotop nwipe libfuse-dev pkg-config libtool fuseiso9660 libimage-exiftool-perl tmfs "
PKGLIST+="tree hashdeep ssdeep bison vbindiff duff "
# firefox is currently a stupid snap
PKGLIST+="firefox ecryptfs-utils libreoffice-base libreoffice-calc libreoffice-core libreoffice-impress libreoffice-writer openoffice.org-hyphenation "

PKGLIST+="array-info "

PKGLIST+="linux-headers-generic "

# vinagre installer - perfomred better than remmina
PKGLIST+="vinagre "

# installing broadcom wifi drivers for some older macs
PKGLIST+="b43-fwcutter firmware-b43-installer "

# adding support for Windows Volume Shadows with vshadowinfo and vshadowmount
PKGLIST+="build-essential debhelper fakeroot autotools-dev libfuse-dev python3-all-dev "
PKGLIST+="libvshadow1 libvshadow-dev libvshadow-utils "

# diffpdf and supporting tools
PKGLIST+="make automake poppler-utils diffpdf "
# boot tools and live image support
PKGLIST+="dialog memtest86+ squashfs-tools hwdata "
PKGLIST+="libx86-1 read-edid xterm "

PKGLIST+="guymager "

PKGLIST+="fred "

PKGLIST+="bruteforce-luks "

#sleuthkit (for mmls and other helpful tools)
PKGLIST+="sleuthkit "

# libfvde - access to filevault encrypted volumes
PKGLIST+="libfvde-utils "

#### DisLocker / bitlocker decryption  https://github.com/Aorimn/dislocker
PKGLIST+="dislocker libbde-utils "

PKGLIST+="openssh-server "

PKGLIST+="ddrescueview "

PKGLIST+="curl "

# Larder toolkit aka the D.U.C.T.T.A.P.E. packages
# Dynamic User Chosen Tools & Tweaks At Primary Execution
# pre-req
PKGLIST+="apt-show-versions libauthen-pam-perl "

PKGLIST+="isc-dhcp-server samba proftpd-core tgt nfs-kernel-server "
# remote access - xrdp needs to be on a later version than in repo
# get from https://github.com/neutrinolabs/xrdp
#PKGLIST+="xrdp tigervnc-standalone-server "
PKGLIST+="tigervnc-standalone-server "
# preferred apt gui for me
PKGLIST+="synaptic "
# webmin dependency
PKGLIST+="libio-pty-perl "
# bulk_extractor dependencies for dev branch
#PKGLIST+="libjson-c-dev "
PKGLIST+="libre2-dev "

# diagnostic I/O tools
PKGLIST+="iotop jnettop "

# adding parallel compresion tools
PKGLIST+="pigz pbzip2 pixz "

# adding blake3
PKGLIST+="b3sum "

# adding wireguard
PKGLIST+="wireguard wireguard-tools "

# Install all the things
apt install -y ${PKGLIST}

# OBS Studio installation
add-apt-repository -y ppa:obsproject/obs-studio
apt update
apt install -y ffmpeg obs-studio

# XRDP installation from github
# dependencies
apt install -y git autoconf libtool pkg-config gcc g++ make libssl-dev \
libpam0g-dev libjpeg-dev libx11-dev libxfixes-dev libxrandr-dev flex bison \
libxml2-dev intltool xsltproc xutils-dev python3-libxml2 xutils libfuse-dev \
libmp3lame-dev nasm libpixman-1-dev xserver-xorg-dev

wget -O /tmp/xrdp-0.10.0.tar.gz https://github.com/neutrinolabs/xrdp/releases/download/v0.10.0/xrdp-0.10.0.tar.gz
tar zxvf /tmp/xrdp-0.10.0.tar.gz
rm -f /tmp/xrdp-0.10.0.tar.gz
cd xrdp-0.10.0
#git clone --recursive https://github.com/neutrinolabs/xrdp.git
#cd xrdp
# cheap hack to fix a bug from libtoolize
#ln -s ../ltmain.sh ltmain.sh
./bootstrap
./configure --enable-fuse --enable-mp3lame --enable-pixman
make
make install
cd ..
rm -rf xrdp*
#rm -rf ltmain.sh
ln -s /usr/local/sbin/xrdp{,-sesman} /usr/sbin
# Note: for headless server installations or multi-desktop installations,you can set the default desktop instance for a login with:
# sudo update-alternatives --config x-session-manager
# This is a fix for issues where XRDP is trying to launch Gnome on a system without a Gnome desktop and it fails after remote login.
# additional fix for xrdp error "Could not acquire name on session bus"
# insert unset right before last fi when building manually on server
#sed -i -e 's/^fi/    unset DBUS_SESSION_BUS_ADDRESS\nfi/' /etc/X11/Xsession.d/80mate-environment
# fix error under mint desktop - replace first fi block for mate
sed -i -e '1,/^fi/{s/^fi/    unset DBUS_SESSION_BUS_ADDRESS\nfi/}' /etc/X11/Xsession.d/99mint
# add gksudo fix for xrdp
echo "export XAUTHORITY=${HOME}/.Xauthority" > /home/${MAINUSER}/.xsessionrc
chown ${MAINUSER} /home/${MAINUSER}/.xsessionrc

# setup ewf-tools with the latest version - much faster than old repo package
apt install -y git autoconf automake autopoint libtool pkg-config flex bison libbz2-dev python3-dev
git clone https://github.com/libyal/libewf.git
cd libewf
./synclibs.sh
# cheap hack to fix a bug from libtoolize
ln -s ../ltmain.sh ltmain.sh
./autogen.sh
./configure --enable-python
make
make install
ldconfig
cd ..
rm -rf libewf
rm -rf ltmain.sh

# setup firewire support - also used by volatility memory analysis plugins
git clone https://github.com/FreddieWitherden/libforensic1394.git
cd libforensic1394
mkdir build
cd build
cmake -G"Unix Makefiles" ../
make
make install
cd ../../
rm -rf libforensic1394

# bulk_extractor - shoehorn style
# this works on 20.04LTS for bulk_extractor 2.0.1 release!
git clone --recursive https://github.com/simsong/bulk_extractor.git
cd bulk_extractor
# removing user interactivity
sed -i '/read IGNORE/d' etc/CONFIGURE_UBUNTU20LTS.bash
# delete all libwef lines since we have a newer and faster one installed
sed -i '/libewf/Id' etc/CONFIGURE_UBUNTU20LTS.bash
set +e # expecting errors - but that's fine
bash etc/CONFIGURE_UBUNTU20LTS.bash
set -e # back to normal
./bootstrap.sh
./configure
make
sudo make install
cd ..
rm -rf bulk_extractor

# BEViewer - extracted from windows releases since it's just a java app
# https://digitalcorpora.s3.amazonaws.com/downloads/bulk_extractor/bulk_extractor-windows-2.0.1.zip - just the processor - viewer not included
# 1.5.5 has the latest and needs to be pulled from there
cp bin/BEViewer.jar /usr/local/bin/
# java -Xmx1g -jar BEViewer.jar

# update the guymager configuration to stop Encase complaints
echo "AvoidEncaseProblems = on" >> /etc/guymager/local.cfg

# turn down the swappiness - only swap if we hit 95 percent
# assuming will probably run on external in most cases
echo "vm.swappiness=5" >> /etc/sysctl.conf

# veracrypt
# find the latest URL - TODO - find and pull from main site
wget -O /tmp/veracrypt.deb https://github.com/veracrypt/VeraCrypt/releases/download/VeraCrypt_1.26.7/veracrypt-1.26.7-Ubuntu-22.04-amd64.deb
apt install -y /tmp/veracrypt.deb
rm /tmp/veracrypt.deb

# install volatility3
apt install -y python3-full python3-dev libpython3-dev python3-pip python3-setuptools python3-wheel
apt install -y python3-distorm3 python3-yara python3-pycryptodome python3-pil python3-openpyxl python3-ujson python3-pytzdata python3-ipython python3-capstone
apt install -y python3-pefile
CWD=`pwd`
cd /opt
git clone https://github.com/volatilityfoundation/volatility3.git
cd volatility3
wget -O /tmp/windows.zip https://downloads.volatilityfoundation.org/volatility3/symbols/windows.zip
unzip /tmp/windows.zip -d ./symbols/
rm /tmp/windows.zip
wget -O /tmp/mac.zip https://downloads.volatilityfoundation.org/volatility3/symbols/mac.zip
unzip /tmp/mac.zip -d ./symbols/
rm /tmp/mac.zip
wget -O /tmp/linux.zip https://downloads.volatilityfoundation.org/volatility3/symbols/linux.zip
unzip /tmp/linux.zip -d ./symbols/
rm /tmp/linux.zip
python3 setup.py build
python3 setup.py install
cd ${CWD}

# cleanup
rm -rf /root/.cache/*

# openssh-server
# remove from autoruns
service ssh stop
update-rc.d ssh disable

# removed tools install in the public version - sorry

# install webmin
wget --no-check-certificate -O /tmp/setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh
# fix for automation
sed -i 's/read -r sslyn/sslyn="y"/' /tmp/setup-repos.sh
sh /tmp/setup-repos.sh
apt-get -y install webmin --install-recommends
rm -fv /webmin-setup.out
rm -fv /tmp/setup-repos.sh

# restrict webmin to localhost
echo "bind=127.0.0.1" >> /etc/webmin/miniserv.conf

# disable network services from auto-starting
systemctl disable isc-dhcp-server
systemctl disable nfs-kernel-server
systemctl disable nmbd
systemctl disable proftpd
systemctl disable smbd
systemctl disable tgt
systemctl disable xrdp
systemctl disable xrdp-sesman
# TODO quicklaunch toggles and docs

# download xrdp config and logo and replace default
cp config/xrdp.ini /etc/xrdp/xrdp.ini
mkdir -p /usr/local/share/blackharrier/
cp images/BH_logo.bmp /usr/local/share/blackharrier/logo.bmp
chown 666 /usr/local/share/blackharrier/logo.bmp

# fix 'could not acquire name on session bus' issue - insert at second line from the bottom before the fi
# temporarily disabled for BH11 dev
###sed -i '$i\ \ \ \ unset DBUS_SESSION_BUS_ADDRESS' /etc/X11/Xsession.d/80mate-environment

#Downloading / installing scripts from blackharrier.net
# password check script
cp script/bhpwdchk.sh /usr/local/bin/bhpwdchk
chmod +x /usr/local/bin/bhpwdchk

# add password check startup script for all users
cp menu/bhpwdchk.desktop /etc/xdg/autostart/bhpwdchk.desktop

# fix all fstab entries to point by UUID to prevent surprises
for DEVICE in $(blkid -o device);
do
    # loop through all the devices and look up uuids
    DEVICEUUID=`blkid -s UUID -o value ${DEVICE}`
    # escape the paths
    echo "${DEVICE//\//\\\/} ==> ${DEVICEUUID}"
    echo sed -i "s/${DEVICE//\//\\\/}/UUID=${DEVICEUUID}/i" /etc/fstab
    sed -i "s/${DEVICE//\//\\\/}/UUID=${DEVICEUUID}/i" /etc/fstab
done

# install wallpaper and set as default
cp images/Black_Harrier.png /usr/share/backgrounds/Black_Harrier.png

# set up the custom grub splash page
cp images/splash.tga /usr/share/grub/splash.tga
echo "GRUB_BACKGROUND=\"/usr/share/grub/splash.tga\"" >> /etc/default/grub
# keep the grub bootloader from going overboard
echo "GRUB_DISABLE_OS_PROBER=true" >> /etc/default/grub

# changing this to something else breaks things on bhreplicate
#sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=\"Black Harrier Linux 11\"/' /etc/default/grub.d/50_linuxmint.cfg

sed -i 's/GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub.d/50_linuxmint.cfg

# update how we identify this in EFI...except it's UCS-2LE format
if [[ ${MODE} == 'EFI' ]]; then
  echo "shimx64.efi,Black Harrier 11,,This is the boot entry for Black Harrier 11" | iconv -t UCS-2LE -o /boot/efi/EFI/ubuntu/BOOTX64.CSV
  echo "shimx64.efi,Black Harrier 11,,This is the boot entry for Black Harrier 11" | iconv -t UCS-2LE -o /usr/lib/shim/BOOTX64.CSV
else
  echo No EFI here - Ignoring
fi

# plymouth themes... just changing the 200x200 image out
# TODO - update themes
cp images/ubuntu-mate-logo.png /usr/share/plymouth/themes/mint-logo/mint-logo.png
cp images/ubuntu-mate-logo16.png /usr/share/plymouth/themes/mint-logo/mint-logo16.png
cp images/animation/*.png /usr/share/plymouth/themes/mint-logo/

# get rid of the resume reference pointing to the swap partition
truncate -s 0 /etc/initramfs-tools/conf.d/resume
# get rid of the swap partition - if it exists
swapoff -a
rm -rf /swapfile
# /swapfile none swap sw 0 0
sed -i 's/\/swapfile.*//' /etc/fstab

update-initramfs -u
update-grub2

# dusable audio
sudo -u ${MAINUSER} -H gsettings set org.mate.sound event-sounds false
sudo -u ${MAINUSER} -H gsettings set org.mate.sound theme-name '__no_sounds'

# set desktop graphics to fit
sudo -u ${MAINUSER} -H gsettings set org.mate.background picture-filename '/usr/share/backgrounds/Black_Harrier.png'
sudo -u ${MAINUSER} -H gsettings set org.mate.background picture-options 'zoom'

# update dconf to prevent autoruns, automounting, other preferences
sudo -u ${MAINUSER} -H gsettings set org.mate.media-handling automount false
sudo -u ${MAINUSER} -H gsettings set org.mate.media-handling automount-open false
sudo -u ${MAINUSER} -H gsettings set org.mate.media-handling autorun-never true

# prevent the display from going to sleep when plugged in
sudo -u ${MAINUSER} -H gsettings set org.mate.power-manager sleep-display-ac 0

# show monitors in panel
sudo -u ${MAINUSER} -H gsettings set org.mate.SettingsDaemon.plugins.xrandr show-notification-icon true

# disable internet search from menu
sudo -u ${MAINUSER} -H gsettings set com.linuxmint.mintmenu.plugins.applications enable-internet-search false

# list view - hidden files - backup files

# Set file manager preferences
sudo -u ${MAINUSER} -H gsettings set org.mate.caja.preferences default-folder-viewer 'list-view'
sudo -u ${MAINUSER} -H gsettings set org.mate.caja.preferences show-hidden-files true
sudo -u ${MAINUSER} -H gsettings set org.mate.caja.preferences show-backup-files true

# clock panel settings - removed since dconf isn't sticking and mate panel prefs were an issue to set

# hide home folder from the desktop
sudo -u ${MAINUSER} -H gsettings set org.mate.caja.desktop home-icon-visible false

# screensaver adjustments - blank only
sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver mode 'blank-only'
sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver lock-enabled false
sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver idle-activation-enabled false
sudo -u ${MAINUSER} -H gsettings set org.mate.screensaver picture-filename '/usr/share/backgrounds/Black_Harrier.png'

# thematic tweaks
sudo -u ${MAINUSER} -H gsettings set org.mate.peripherals-mouse cursor-theme 'Adwaita'
mkdir -p /usr/share/icons/blackharrier
chmod +x /usr/share/icons/blackharrier
cp icon/crowhead.svg /usr/share/icons/blackharrier/crowhead.svg
# change the icon so we know it's BH11 on the menu
sudo -u ${MAINUSER} -H gsettings set com.linuxmint.mintmenu applet-icon '/usr/share/icons/blackharrier/crowhead.svg'

# adjust synaptic preferences - clean cache and delete old history to save space
# disable die on error for greps that may miss

# if we are missing the synaptic config - download it.
if [ ! -f /root/.synaptic/synaptic.conf ]; then
  mkdir -p /root/.synaptic
  cp config/synaptic.conf /root/.synaptic/synaptic.conf
fi

set +e
CHK=`grep -o '  CleanCache' /root/.synaptic/synaptic.conf`
set -e
if [[ ${CHK} == '  CleanCache' ]]; then
  # change setting
  sed -i 's/^  CleanCache.*/  CleanCache "true";/' /root/.synaptic/synaptic.conf
else
  # inject setting
  sed -i '2 i \ \ CleanCache "true";' /root/.synaptic/synaptic.conf
fi

set +e
CHK=`grep -o '  delHistory' /root/.synaptic/synaptic.conf`
set -e
if [[ ${CHK} == '  delHistory' ]]; then
  # change setting
  sed -i 's/^  delHistory.*/  delHistory "30";/' /root/.synaptic/synaptic.conf
else
  # inject setting
  sed -i '2 i \ \ delHistory "30";' /root/.synaptic/synaptic.conf
fi

# cleanup downloaded packages
apt clean

# add icons
cp icon/photorec.png /usr/share/icons/photorec.png
cp icon/testdisk.png /usr/share/icons/testdisk.png

mkdir -p /usr/local/share/blackharrier/menus/

# Download all the menu entry support files
cp menu/bulk_extractor_viewer.desktop /usr/local/share/blackharrier/menus/bulk_extractor_viewer.desktop
cp menu/file_manager.desktop /usr/local/share/blackharrier/menus/file_manager.desktop
cp menu/forensic_tools.directory /usr/local/share/blackharrier/menus/forensic_tools.directory
cp menu/fred.desktop /usr/local/share/blackharrier/menus/fred.desktop
cp menu/gtkhash.desktop /usr/local/share/blackharrier/menus/gtkhash.desktop
cp menu/guymager.desktop /usr/local/share/blackharrier/menus/guymager.desktop
cp menu/mate-network-scheme.desktop /usr/local/share/blackharrier/menus/mate-network-scheme.desktop
cp menu/netdiscover.desktop /usr/local/share/blackharrier/menus/netdiscover.desktop
cp menu/network.desktop /usr/local/share/blackharrier/menus/network.desktop
cp menu/network_forensics.directory /usr/local/share/blackharrier/menus/network_forensics.directory
cp menu/network_tools.desktop /usr/local/share/blackharrier/menus/network_tools.desktop
cp menu/photorec.desktop /usr/local/share/blackharrier/menus/photorec.desktop
cp menu/testdisk.desktop /usr/local/share/blackharrier/menus/testdisk.desktop
cp menu/wireshark.desktop /usr/local/share/blackharrier/menus/wireshark.desktop
cp menu/xdeview.desktop /usr/local/share/blackharrier/menus/xdeview.desktop
cp menu/xhfs.desktop /usr/local/share/blackharrier/menus/xhfs.desktop

# make them executable
find /usr/local/share/blackharrier/menus/ -type f -exec chmod +x '{}' \;
# install the menu entires
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/bulk_extractor_viewer.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/file_manager.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/fred.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/gtkhash.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/guymager.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/network_tools.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/photorec.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/testdisk.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/xdeview.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/xhfs.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/network_forensics.directory /usr/local/share/blackharrier/menus/mate-network-scheme.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/network_forensics.directory /usr/local/share/blackharrier/menus/netdiscover.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/network_forensics.directory /usr/local/share/blackharrier/menus/network.desktop
xdg-desktop-menu install --noupdate --novendor --mode system /usr/local/share/blackharrier/menus/forensic_tools.directory /usr/local/share/blackharrier/menus/network_forensics.directory /usr/local/share/blackharrier/menus/wireshark.desktop

# fix wifi scanning policy on remote sessions
mkdir -pv /etc/polkit-1/localauthority/50-local.d/
echo "[Allow Wifi Scan]
Identity=unix-user:*
Action=org.freedesktop.NetworkManager.wifi.scan;org.freedesktop.NetworkManager.enable-disable-wifi;org.freedesktop.NetworkManager.settings.modify.own;org.freedesktop.NetworkManager.settings.modify.system;org.freedesktop.NetworkManager.network-control
ResultAny=yes
ResultInactive=yes
ResultActive=yes
" > /etc/polkit-1/localauthority/50-local.d/47-allow-wifi-scans.pkla

# update the menu
xdg-desktop-menu forceupdate

# delete extra backgrounds and save space
find /usr/share/backgrounds/ -type f -not -path '*Black_Harrier*' -delete

# download the general system cleanup script and drop it in the root sbin
cp script/bhreplicate.sh /usr/local/sbin/bhreplicate
chmod +x /usr/local/sbin/bhreplicate

# download the system update script and drop it in the root sbin
cp script/bhupdate.sh /usr/local/sbin/bhupdate
chmod +x /usr/local/sbin/bhupdate

# delete all passwords if we are in portable mode - leave alone for workstation
if [ ${SETUPMODE} == "portable" ]; then
	sed -i 's/:$[^:]*:/:*:/g' /etc/shadow
	# delete backup shadow file
	rm -f /etc/shadow-
fi

# a few final cleanups
rm -rf /root/.wget-hsts
truncate -s 0 /home/${MAINUSER}/.bash_history
rm -rf /home/${MAINUSER}/.xsession-errors*
rm -rf /home/${MAINUSER}/.cache/*
rm -rf /home/${MAINUSER}/.ssh/known_hosts
rm -rf /root/.ssh/known_hosts
truncate -s 0 /root/.bash_history
history -c

# LSB release tweak and create the right boot menu entries
sed -i 's/DISTRIB_ID.*/DISTRIB_ID=BlackHarrier/' /etc/lsb-release
sed -i 's/DISTRIB_RELEASE.*/DISTRIB_RELEASE=11/' /etc/lsb-release
sed -i 's/DISTRIB_CODENAME.*/DISTRIB_COENAME=\"BH11Mint\"/' /etc/lsb-release
sed -i 's/DISTRIB_DESCRIPTION.*/DISTRIB_DESCRIPTION=\"Black Harrier Linux 11\"/' /etc/lsb-release

echo "Installation complete. Thank you for your patience and choosing Black Harrier Linux. This system will reboot in 5 seconds to complete the installation process."
sleep 5
reboot
exit
