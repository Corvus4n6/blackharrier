#!/bin/bash
# BlackHarrier11 OTG Setup script
# OTG = Off The Grid / On The Go /
# Set up local offline repositories enabling software instalation and updates
# without internet access
# Apt repos for linux mint and ubuntu
#
# halt on error
set -e

# make sure we are running as root
if [[ ${EUID} -ne 0 ]]; then
   echo "This program must be run as root"
   exit 1
fi

# arg parsing - default is to sync unless we specify setup
while (( "$#" )); do
  case "$1" in
    -s|--setup)
      # turn on luks encryption - script will ask for passwords later
      SETUP="true"
      shift
      ;;
      -h|--help)
        # display help and exit
        echo "NAME
      bhotg - Black Harrier Off The Grid / On The Go - Download copies of
      software repositories to the local disk to install packages when offline.

SYNOPSIS
      bhotg [options]

DESCRIPTION
      bhotg will download and store a copy of the binary packages for the
      underlying LinuxMint and Ubuntu packages to the local disk. This will
      take up 250GB or more of drive space, but may prove helpful in situations
      where internet connectivity is unreliable or unavailable and you really,
      really need to install something.

OPTIONS
      <default>
              Running the program without an option will update the local
              respoitory files, but will not modify the list of sources.

      -s | --setup
              Setup the bhotg feature. This will modify the apt sources file to
              point to the local disk and will download amd64 binary packages
              to the /opt/apt directory.

      -h | --help
              Display this help page." | more
        exit 0
  	  shift
        ;;
      --) # end argument parsing
        shift
        break
        ;;
      -*|--*=) # unsupported flags
        echo "Error: Unsupported flag ${1}" >&2
  	    echo "See: bhotg --help"
        exit 1
        ;;
    esac
  done

if [[ "$SETUP" == "true" ]]; then

  FREESPACE=`df --output="avail" | tail -1`
  echo ${FREESPACE}
  if [ "${FREESPACE}" -lt "250000000" ]; then
    # WARN we are low on disk space
    printf "Your root partition has less than 250GB free. You may run out of space. Continue? [Y/n]: "
    read SPACEWARN
    if [[ "${SPACEWARN}" != "Y" ]]; then
      exit
    fi
  fi

fi

# make destinations - or make sure they exist
mkdir -v /opt/apt/mint -p
mkdir -v /opt/apt/ubuntu -p

# mirror the ubuntu repo metadata
rsync -r -l -p -t -z --progress --delete -v --include="project**" --exclude="*" rsync://archive.ubuntu.com/ubuntu /opt/apt/ubuntu
rsync -r -l -p -t -z --progress --delete -v --include="dists" --include="**noble**" --exclude="*" rsync://archive.ubuntu.com/ubuntu /opt/apt/ubuntu
rsync -r -l -p -t -z --progress --delete -v --include="indices" --include="**noble**" --exclude="*" rsync://archive.ubuntu.com/ubuntu /opt/apt/ubuntu
# then generate a list of binary files we will need for amd64 only
xzcat /opt/apt/ubuntu/dists/noble*/*/binary-amd64/Packages.xz | grep -E "^Filename: " | sed 's/Filename: //' | soirt -u > /tmp/rsynclist.txt
# just syncing the current binaries amd64
rsync -r -l -p -t -z --files-from=/tmp/rsynclist.txt --delete -v rsync://archive.ubuntu.com/ubuntu /opt/apt/ubuntu

# mirror linux mint metadata
rsync -r -l -p -t -z --progress --delete --include="db**" --exclude="*" rsync-packages.linuxmint.com::packages /opt/apt/mint
rsync -r -l -p -t -z --progress --delete --include="dists" --include="**wilma**" rsync-packages.linuxmint.com::packages /opt/apt/mint
# generate a list of amd64 binaries to pull down
xzcat /opt/apt/mint/dists/wilma/*/binary-amd64/Packages.xz | grep "Filename: " | sed 's/Filename: //' | sort -u > /tmp/mintrsync.txt
# download binaries
rsync -r -l -p -t -z --progress --files-from=/tmp/mintrsync.txt --delete rsync-packages.linuxmint.com::packages /opt/apt/mint

if [[ "$SETUP" == "true" ]]; then

  printf "Updating apt source files to point to local storage."
  # comment out the online repos
  sed -i -E 's/^deb/#deb/' /etc/apt/sources.list.d/official-package-repositories.list
  # add the local repos
  echo '
  deb file:///opt/apt/mint wilma main upstream import backport
  deb file:///opt/apt/ubuntu noble main restricted universe multiverse
  deb file:///opt/apt/ubuntu noble-updates main restricted universe multiverse
  deb file:///opt/apt/ubuntu noble-backports main restricted universe multiverse
  deb file:///opt/apt/ubuntu noble-security main restricted universe multiverse
  ' >> /etc/apt/sources.list.d/official-package-repositories.list

fi

printf "Local copies of the repositories have been downloaded. To update/sync your repositories run the bhotg command again."
