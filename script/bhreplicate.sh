#!/bin/bash
# BlackHarrier11 Replicator script - EFI mode
# a bit of a cheat with the same uuid's but less breakage this way
# 20190829 - changed this script to combine gpt and mbr formats in one script

# TODO 20220419 - encrypt on mbr not booting mbr->enc-mbr

# TODO - make a network-based replicator / offline replicator package
# TODO - suspend to disk is borken, but EFI/ENC swap partition works. Test all scen.
# This script is designed to take an existing setup of BH11 and replicate it to
# another block device.
#
# usage: BHReplicate.sh <device>
# where <device> is the target block device such as /dev/sdX
#
# Need to add lots of checks in here, but assuming ${DEVICE} is the block device
#
# Rewriting for Ubuntu-Mate-10.10-Cosmic with direct EFI partition replication
# TODO - add lv / vg close and luksclose to enc setup
# TODO - add a groundhog day option to build more copies with the same config
#
# 64-bit AMD x86_64
# efi clr -> clr # works minty base 20240121
# efi clr -> fde # works minty base 20240121
# efi fde -> fde # works minty base 20240121
# efi fde -> clr # works minty base 20240121
# mbr install will boot to efi in a pinch
# MBR builder will need a complete rewrite
# mbr clr -> clr # works minty base 20240121
# mbr clr -> fde # works minty base 20240121
# mbr fde -> fde # boot fail - this is a problem because /boot is not mounted
# mbr fde -> clr # boot fail
# efi -> mbr #
# mbr -> efi #
# secure boot install works

set -e
#set -x

# preset some vars
ENCRYPT="false"

load_check() {
    LOAD=`cat /proc/loadavg | awk '{print $1}'`
    LOADMAX=`lscpu | grep -E "^CPU\(s\):" | awk '{print $2}'`
    #LOADMAX=1
    if [[ $(echo "${LOAD} < ${LOADMAX}"|bc) -eq 0 ]] ; then
        echo "System load is at $LOAD. Enhancing calm..."
        sleep 60
        load_check
    fi
}

dectobase36(){
    # a little thing to give me a six byte unique value for naming things
    BASE36=($(echo {0..9} {A..Z}));
    arg1=$@;
    for i in $(bc <<< "obase=36; $arg1"); do
    echo -n ${BASE36[$(( 10#$i ))]}
    done && echo
}

load_check

#preset
SWAPSIZE=0
SWAPSIZEM=0

# arg parsing
while (( "$#" )); do
  case "$1" in
    -f|--flag-with-argument)
	  # holding for reference about how to handly these args
      FARG=$2
      shift 2
      ;;
    -e|--encrypt)
      # turn on luks encryption - script will ask for passwords later
      ENCRYPT="true"
      shift
      ;;
    -i|--insecure)
      # skip wiping free space
      INSECURE="true"
      shift
      ;;
    -s|--swap)
      # switch from swap file to swap-partition @ 1.25x ram (for hibernation)
      HIBERFIL="true"
	  # calculate size of hibernation file needed
	  RAMSIZE=`free -b | grep "Mem:" | awk '{ print $2}'`
	  SWAPSIZE=`printf %.0f $(echo "${RAMSIZE} * 1.25" | bc)`
	  SWAPSIZEM=`printf %.0f $(echo "(${RAMSIZE} * 1.25) / 1048576" | bc)`
      shift
      ;;
    -c|--chuser)
      # change the current user and group (uid/gid=1000) to another name
	  # will take place post-rsync
      NEWUSER="true"
      shift
      ;;
    -x|--expand)
      # fill target media
      FILLTARGET="true"
      shift
      ;;
    -l|--lazyinit)
      # fill target media
      LAZYINIT="true"
      shift
      ;;
    -h|--help)
      # display help and exit
      echo "NAME
      bhreplicate - Replicate the current, active system to a new device

SYNOPSIS
      bhreplicate [options] <target block device>

DESCRIPTION
      bhreplicate is intended for replicating the currently running and
      configured BlackHarrier system to new media. Typically this is done to
      prepare new media for use in the field, to quickly set up a forensic
      workstation, or to mass-produce imaging toolkits without having to wait
      for full bit-copies of a single device.

OPTIONS

      -e | --encrypt
              Encrypt the target device root partition using LUKS. Password
              will be requested during the formatting of the target media.

      -i | --insecure
              Skip wiping of free space at the end of the process. This may be
              a significant time saver at the time of replication but at the
              potential cost of security if you lose your target device.

      -s | --swap
              Create a swap partition sized at 1.25x installed memory. This
              option is helpful for workstation installations when larger swap
              and the ability to hibernate may be desired.

      -c | --chuser
              Change the current user and group name (uid/gid=1000) on the
              target media.

      -x | --expand
              Expand the root partition to fill the target device.

      -l | --lazyinit
              Complete initialization of ext4 formatted partitions at the next
              mount to save time during replication.

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
	    echo "See: bhreplicate --help"
      exit 1
      ;;
    *) # preserve positional arguments
      DEVICE=${1}
      shift
      ;;
  esac
done

MODE="EFI"

# make sure we are running as root
if [[ ${EUID} -ne 0 ]]; then
   echo "This setup script must be run as root"
   exit 1
fi

# TODO - better arg parsing - add hiberfil/swap partition option
# recomended swap partition size is 1.25x installed ram.

# TODO - user changing option to rename 'harrier' to something else

# chuser needs to adjust files:
# /etc/lightdm/lightdm.conf
# /etc/group-
# /etc/shadow
# /etc/subgid
# /etc/group
# /etc/gshadow
# /etc/sudoers
# /etc/passwd (to also change display name)
# /etc/subuid
# /etc/passwd-

if [[ ${DEVICE} == "" ]]; then
  # device cannot be empty
  echo "Please specify the target device. See: bhreplicate --help "
  exit 1
fi

# make sure the destination device exists
if [[ -b ${DEVICE} ]] ; then
	# we got a block device!
	echo "Installing to device ${DEVICE}"
	#if [[ "$(uname -m)" == "x86_64" ]]; then
  #  	lsblk -T PATH -o PATH,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINT ${DEVICE}
  #  else
    	lsblk -o NAME,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINT ${DEVICE}
  #  fi
else
	# this is not a block device
	echo "Error: Device ${DEVICE} is not a block device"
	exit 1
fi

# determine what kind of system (UEFI/BIOS) this is and react accordingly
# TODO - allow user override via switch
# TODO - network package building switch
if [[ -e /sys/firmware/efi ]]; then
	echo "Replicating GPT/EFI system"
	# continue
else
	echo "Switching to MBR replication"
	MODE="MBR"
#else
#	echo "Unexpected disk label."
#	read -p "Perform network-based replication [y/n] " choice
#	case $choice in
#		y) exec bhreplicateinet ${DEVICE} ;;
#		Y) exec bhreplicateinet ${DEVICE} ;;
#		*) exit 1
#	esac
#	# TODO - write it
#	MODE="NET"
fi

if [[ "${NEWUSER}" == "true" ]]; then
	# get username and displayname preferred for target
	printf "New username for target? "
	read NEWUSERNAME
	printf "New display name for target? "
	read NEWUSERDISP
	# TODO - add checks
fi

if [[ ${MODE} == "EFI" ]]; then
    # lay down a partition structure - need to add options for GPT vs MSDOS
    PREVDIR=`pwd`
    ROOTUUID=`findmnt -M / -n -o UUID`
    if [[ "${ENCRYPT}" == "true" ]]; then
      # separate boot partition for encrypted setups
      # TODO under set -e this will cause it to die if no /boot mount
      BOOTUUID=`findmnt -M /boot -n -o UUID`
    fi
    EFIUUID=`findmnt -M /boot/efi -n -o UUID`

	# if they didn't set the --eXpand option - ask
	if [[ "${FILLTARGET}" != "true" ]]; then
	    printf "Expand root partition to fill target media? [Y/n]: "
	    read FILLDISK
	else
		FILLDISK="Y"
	fi
    if [[ "${FILLDISK}" == "n" ]] || [[ "${FILLDISK}" == "N" ]]; then
        # get desired size for target root partition in GiB
        # minimum 8GiB...and that's very tight
        echo "Disk ${DEVICE} has $(lsblk -dno SIZE ${DEVICE}) available."
        FULLTARGET=$(lsblk -bdno SIZE ${DEVICE})
        if [[ "${ENCRYPT}" == "true" ]]; then
            FREESPACE=$(expr ${FULLTARGET} - 805306368 - ${SWAPSIZE})
        else
            FREESPACE=$(expr ${FULLTARGET} - 537395200 - ${SWAPSIZE})
        fi
        MINSPACE=$(expr 8 * 1073741824)
        # 1073741824 bytes per GiB.
        # or multiply by 0.93132257462
        printf "Desired size for root partition in GiB: "
        read ROOTSIZE
        ROOTMINCHK=`echo "(${ROOTSIZE}*1073741824) < ${MINSPACE}" | bc`
        if [[ "$ENCRYPT" == "true" ]]; then
            ROOTMAXCHK=`echo "((${ROOTSIZE}*1073741824)+805306368+${SWAPSIZE}) > ${FREESPACE}" | bc`
        else
            ROOTMAXCHK=`echo "((${ROOTSIZE}*1073741824)+537395200+${SWAPSIZE}) > ${FREESPACE}" | bc`
        fi

        if [[ "${ROOTMINCHK}" == "1" ]]; then
            echo "Root partition must be at least 8GB"
            exit 1
        fi

        if [[ "${ROOTMAXCHK}" == "1" ]]; then
            echo "Setting to maximum."
            ROOTEND="-1MiB"

        else
            # calculate end in GiB...ish.
            ROOTENDVAL=`echo ${ROOTSIZE}+0.5 | bc`
            ROOTEND="${ROOTENDVAL}GiB"
            if [[ "${INSECURE}" != "true" ]]; then
                printf "Wipe remaining sectors on disk? [Y/n]: "
                read WIPEFREEDISK

                if [[ "${WIPEFREEDISK}" == "" ]] || [[ "${WIPEFREEDISK}" == "y" ]] || [[ "${WIPEFREEDISK}" == "Y" ]]; then
                    # will create a final partition and overwrite with zeroes
                    WIPEFREE="TRUE"
                fi
            fi
        fi

    else
        ROOTEND="-1MiB"

    fi

    if [[ "$ENCRYPT" == "true" ]]; then
        parted ${DEVICE} -- mklabel gpt
        sync
        # /boot/efi FAT partition
        parted -s ${DEVICE} -- mkpart primary 2048s 512MiB
        sync
        # /boot ext4 partition
        parted -s ${DEVICE} -- mkpart primary 512MiB 768MiB
        sync
        # [root] ext4 partition
        parted -s ${DEVICE} -- mkpart primary 768MiB ${ROOTEND}
        sync
        if [[ "${WIPEFREE}" == "TRUE" ]]; then
            parted -s ${DEVICE} -- mkpart primary ${ROOTEND} -1MiB
            sync
        fi
        parted -s ${DEVICE} -- set 1 boot on
        parted -s ${DEVICE} -- set 1 esp on
        sync
        echo "Pausing to let the dust settle..."
        sleep 5

        if [[ "${WIPEFREE}" == "TRUE" ]]; then
            echo "Wiping free sectors at back of disk...."
            set +e
            dcfldd pattern=00 of=${DEVICE}4
            set -e
            # delete partition at back of disk
            parted -s ${DEVICE} -- rm 4
            sync
            sleep 5
        fi

        # formatting partition1 fat32 /boot/efi
        mkfs.vfat -F 32 -I ${DEVICE}1
        parted -s ${DEVICE} name 1 '"EFI System Partition"'
        sync
        # formatting partition2 ext4 - force in case we are overwriting an old system
        sleep 3
        # /boot
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F ${DEVICE}2
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F ${DEVICE}2
            sync
        fi

        NOWTIME=`date +%s`
        UNIQUE=`dectobase36 ${NOWTIME}`

        echo "Creating encrypted partition..."
        # make the main partition encrypted with luks
        cryptsetup -q -v -y luksFormat ${DEVICE}3
        sync
        echo "Unlocking encrypted partition..."
        cryptsetup luksOpen ${DEVICE}3 BH11.${UNIQUE}
        # formatting partition3 ext4 - force in case we are overwriting an old system
        #mkfs.ext4 -F /dev/${DEVICE}3

        # create lvm's - and optional swap partition
		if [[ "${HIBERFIL}" == "true" ]]; then
			# get size of ${DEVICE}3
			# in this case returns more than one device size
			lsblk
			PVSIZEB=`lsblk -b -no SIZE ${DEVICE}3 | head -1`
			LVSIZEM=`printf %.0f $(echo "(${PVSIZEB} - ${SWAPSIZE}) / 1048576" | bc)`
			echo PVSIZEB: ${PVSIZEB}
			echo SWAPSIZE: ${SWAPSIZE}
			echo LVSIZEM: ${LVSIZEM}
	        pvcreate /dev/mapper/BH11.${UNIQUE}
	        vgcreate BH11.${UNIQUE} /dev/mapper/BH11.${UNIQUE}
	        lvcreate -L ${LVSIZEM}m -nroot BH11.${UNIQUE}
	        lvcreate -l 100%FREE -nswap BH11.${UNIQUE}
			sync
		else
	        pvcreate /dev/mapper/BH11.${UNIQUE}
	        vgcreate BH11.${UNIQUE} /dev/mapper/BH11.${UNIQUE}
	        lvcreate -l 100%FREE -nroot BH11.${UNIQUE}
	        sync
		fi

        # [root] - encrypted
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F /dev/mapper/BH11.${UNIQUE}-root
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F /dev/mapper/BH11.${UNIQUE}-root
            sync
        fi

		if [[ "${HIBERFIL}" == "true" ]]; then
		    SWAPUUID=`uuidgen`
			mkswap -U ${SWAPUUID} /dev/mapper/BH11.${UNIQUE}-swap
		fi

        ## mount the target filesystem and copy all the relevant data
        # root
        mkdir -p /media${DEVICE}2
        mount -o rw /dev/mapper/BH11.${UNIQUE}-root /media${DEVICE}2
        # boot
        mkdir -p /media${DEVICE}2/boot
        mount -o rw ${DEVICE}2 /media${DEVICE}2/boot
        # boot/efi
        mkdir -p /media${DEVICE}2/boot/efi
        mount -t vfat -o rw ${DEVICE}1 /media${DEVICE}2/boot/efi

        BOOTMOUNT="/media${DEVICE}1"
        ROOTMOUNT="/media${DEVICE}2"
    fi
    # end of encrypted setup
    if [[ "$ENCRYPT" != "true" ]]; then
        parted ${DEVICE} -- mklabel gpt
        sync
        # /boot/efi FAT partition
        parted -s ${DEVICE} -- mkpart primary 2048s 512MiB
        sync
        # [root] ext4 partition
        parted -s ${DEVICE} -- mkpart primary 512MiB ${ROOTEND}
        sync
        if [[ "${WIPEFREE}" == "TRUE" ]]; then
            parted -s ${DEVICE} -- mkpart primary ${ROOTEND} -1MiB
            sync
        fi
        parted -s ${DEVICE} -- set 1 boot on
        parted -s ${DEVICE} -- set 1 esp on
        sync
        echo "Pausing to let the dust settle..."
        sleep 5

        if [[ "${WIPEFREE}" == "TRUE" ]]; then
            echo "Wiping free sectors at back of disk...."
            set +e
            dcfldd pattern=00 of=${DEVICE}3
            set -e
            # delete partition at back of disk
            parted -s ${DEVICE} -- rm 3
            sync
            sleep 5
        fi

        # formatting partition1 fat32 /boot/efi
        mkfs.vfat -F 32 -I ${DEVICE}1
        parted -s ${DEVICE} name 1 '"EFI System Partition"'
        sync
        # formatting partition2 ext4 - force in case we are overwriting an old system
        sleep 3
        # / [root]
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F ${DEVICE}2
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F ${DEVICE}2
            sync
        fi

        ## mount the target filesystem and copy all the relevant data
        #mkdir -p /media${DEVICE}1
        mkdir -p /media${DEVICE}2
        #mount ${DEVICE}1 /media${DEVICE}1
        mount -o rw ${DEVICE}2 /media${DEVICE}2
        mkdir -p /media${DEVICE}2/boot/efi
        mount -t vfat -o rw ${DEVICE}1 /media${DEVICE}2/boot/efi
        # interesting problem in a VM - the vfat partition does not mount correctly when the system is swapping
        # this leads to errors on the rsync and failed replication
        BOOTMOUNT="/media${DEVICE}1"
        ROOTMOUNT="/media${DEVICE}2"
    fi
    # end of non-encrypted

elif [[ ${MODE} == "MBR" ]]; then
    # lay down a partition structure - need to add options for GPT vs MSDOS
    PREVDIR=`pwd`
    ROOTUUID=`findmnt -M / -n -o UUID`

    # do some math for the partition sizing
	# if they didn't set the --eXpand option - ask
	if [[ "${FILLTARGET}" != "true" ]]; then
	    printf "Expand root partition to fill target media? [Y/n]: "
	    read FILLDISK
	else
		FILLDISK="Y"
	fi

    if [[ "${FILLDISK}" == "n" ]] || [[ "${FILLDISK}" == "N" ]]; then
        # get desired size for target root partition in GiB
        # minimum 8GiB...and that's very tight
        echo "Disk ${DEVICE} has $(lsblk -dno SIZE ${DEVICE}) available."
        FULLTARGET=$(lsblk -bdno SIZE ${DEVICE})
        if [[ "$ENCRYPT" == "true" ]]; then
            FREESPACE=$(expr $FULLTARGET - 268437504)
        else
            FREESPACE=$(expr $FULLTARGET - 2048)
        fi
        MINSPACE=$(expr 8 * 1073741824)
        # 1073741824 bytes per GiB.
        # or multiply by 0.93132257462
        printf "Desired size for root partition in GiB: "
        read ROOTSIZE
        ROOTMINCHK=`echo "(${ROOTSIZE}*1073741824) < ${MINSPACE}" | bc`
        if [[ "$ENCRYPT" == "true" ]]; then
            ROOTMAXCHK=`echo "((${ROOTSIZE}*1073741824)+268437504) > ${FREESPACE}" | bc`
        else
            ROOTMAXCHK=`echo "((${ROOTSIZE}*1073741824)+2048) > ${FREESPACE}" | bc`
        fi

        if [[ "${ROOTMINCHK}" == "1" ]]; then
            echo "Root partition must be at least 8GB"
            exit 1
        fi

        if [[ "${ROOTMAXCHK}" == "1" ]]; then
            echo "Setting to maximum."
            ROOTEND="-1MiB"

        else
            # calculate end in GiB...ish.
            ROOTENDVAL=${ROOTSIZE}
            ROOTEND="${ROOTENDVAL}GiB"
            if [[ "${INSECURE}" != "true" ]]; then
                printf "Wipe remaining sectors on disk? [Y/n]: "
                read WIPEFREEDISK

                if [[ "${WIPEFREEDISK}" == "" ]] || [[ "${WIPEFREEDISK}" == "y" ]] || [[ "${WIPEFREEDISK}" == "Y" ]]; then
                    # will create a final partition and overwrite with zeroes
                    WIPEFREE="TRUE"
                fi
            fi
        fi

    else
        ROOTEND="-1MiB"

    fi

	if [[ "$HIBERFIL" == "true" ]]; then
		# alter the end of the root to give us space for the swap file
		# in MiB
		ROOTENDINT=`echo "(${FREESPACE} - ${SWAPSIZE}) / 1048576" | bc)`
	fi

    #BOOTUUID=`findmnt -M /boot/efi -n -o UUID | sed 's/\-//g'`
    parted ${DEVICE} -- mklabel msdos
    # leaving out the -s to keep accidents to a minimum
    #parted ${DEVICE} -- mklabel gpt
    sync
    # need to leave a little space at the front for grub
    # / [root]
    if [[ "$ENCRYPT" != "true" ]]; then
			if [[ "$HIBERFIL" == "true" ]]; then
				# root
		        parted -s ${DEVICE} -- mkpart primary 2048s ${ROOTENDINT}MiB
				# swap
		        parted -s ${DEVICE} -- mkpart primary ${ROOTENDINT}MiB -1MiB
		        sync
			else
		        parted -s ${DEVICE} -- mkpart primary 2048s ${ROOTEND}
		        sync
			fi
    else
        # need to make boot and luks
        parted -s ${DEVICE} -- mkpart primary 2048s 256MiB
        sync
        parted -s ${DEVICE} -- mkpart primary 256MiB ${ROOTEND}
        sync
    fi
    # blank space to be optionally wiped
    if [[ "${WIPEFREE}" == "TRUE" ]]; then
        parted -s ${DEVICE} -- mkpart primary ${ROOTEND} -1MiB
        sync
    fi
    echo "Pausing to let the dust settle..."
    sleep 5

    if [[ "${WIPEFREE}" == "TRUE" ]] && [[ "$ENCRYPT" != "true" ]] ; then
        echo "Wiping free sectors at back of disk...."
        set +e
        dcfldd pattern=00 of=${DEVICE}2
        set -e
        # delete partition at back of disk
        parted -s ${DEVICE} -- rm 2
        sync
        sleep 5
    fi
    if [[ "${WIPEFREE}" == "TRUE" ]] && [[ "$ENCRYPT" == "true" ]] ; then
        echo "Wiping free sectors at back of disk...."
        set +e
        dcfldd pattern=00 of=${DEVICE}3
        set -e
        # delete partition at back of disk
        parted -s ${DEVICE} -- rm 3
        sync
        sleep 5
    fi
    if [[ "$ENCRYPT" != "true" ]]; then
        # / root partition
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F ${DEVICE}1
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F ${DEVICE}1
            sync
        fi

        ## mount the target filesystem and copy all the relevant data
        mkdir -p /media${DEVICE}1
        mount -o rw ${DEVICE}1 /media${DEVICE}1
        #mkdir -p /media${DEVICE}2
        # TODO - normaize the mount point across this script
        ROOTMOUNT="/media${DEVICE}1"
    else
        # /boot partition
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F ${DEVICE}1
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F ${DEVICE}1
            sync
        fi

        # / [root] partition
        echo "Creating encrypted partition..."
        # make the main partition encrypted with luks
        cryptsetup -q -v -y luksFormat ${DEVICE}2
        sync

        NOWTIME=`date +%s`
        UNIQUE=`dectobase36 ${NOWTIME}`

        echo "Unlocking encrypted partition..."
        cryptsetup luksOpen ${DEVICE}2 BH11.${UNIQUE}
        # formatting partition3 ext4 - force in case we are overwriting an old system
        #mkfs.ext4 -F /dev/${DEVICE}3

        # create lvm
        pvcreate /dev/mapper/BH11.${UNIQUE}
        vgcreate BH11.${UNIQUE} /dev/mapper/BH11.${UNIQUE}
		if [[ "${HIBERFIL}" == "true" ]]; then
			# root
	        lvcreate -L ${ROOTENDINT}m -nroot BH11.${UNIQUE}
			# swap at the end
	        lvcreate -l 100%FREE -nswap BH11.${UNIQUE}
		else
	        lvcreate -l 100%FREE -nroot BH11.${UNIQUE}
		fi
        sync

        # [root] - encrypted
        if [[ "${LAZYINIT}" == "TRUE" ]]; then
            # allow system to finish format after mounting
            mkfs.ext4 -F /dev/mapper/BH11.${UNIQUE}-root
            sync
        else
            # pay for the time penalty up front (default)
            mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F /dev/mapper/BH11.${UNIQUE}-root
            sync
        fi

		if [[ "${HIBERFIL}" == "true" ]]; then
			mkswap /dev/mapper/BH11.${UNIQUE}-swap
		fi
        sync

        mkdir -p /media${DEVICE}2
        mount -o rw /dev/mapper/BH11.${UNIQUE}-root /media${DEVICE}2
        mkdir -p /media${DEVICE}2/boot
        # removing redundant boot mountpoint
        #mount -o rw ${DEVICE}1 /media${DEVICE}2/boot
        if [[ ${MODE} == "EFI" ]]; then
          mount -o rw ${DEVICE}2 /media${DEVICE}2/boot
          mount -o rw ${DEVICE}1 /media${DEVICE}2/boot/efi
        else
          mount -o rw ${DEVICE}1 /media${DEVICE}2/boot
        fi
        ROOTMOUNT="/media${DEVICE}2"
    fi

else
	echo "Error: unxepected"
	exit 1
fi


if [[ ${MODE} == "EFI" && "$ENCRYPT" == "true" ]]; then
  # get the UUID of the new root partition
  NEWROOTUUID=`findmnt -M "${ROOTMOUNT}" -n -o UUID`
  echo "New Root UUID: ${NEWROOTUUID}"
  NEWBOOTUUID=`findmnt -M "${ROOTMOUNT}/boot" -n -o UUID`
  echo "New Boot UUID: ${NEWBOOTUUID}"
  NEWEFIUUID=`findmnt -M "${ROOTMOUNT}/boot/efi" -n -o UUID`
  echo "New EFI UUID: ${NEWEFIUUID}"
elif [[ ${MODE} == "EFI" && "$ENCRYPT" != "true" ]]; then
  # get the UUID of the new root partition
  NEWROOTUUID=`findmnt -M "${ROOTMOUNT}" -n -o UUID`
  echo "New Root UUID: ${NEWROOTUUID}"
  NEWEFIUUID=`findmnt -M "${ROOTMOUNT}/boot/efi" -n -o UUID`
  echo "New EFI UUID: ${NEWEFIUUID}"
elif [[ ${MODE} == "MBR"  && "$ENCRYPT" == "true" ]]; then
  # get the UUID of the new root partition
  NEWROOTUUID=`findmnt -M ${ROOTMOUNT} -n -o UUID`
  echo "New Root UUID: ${NEWROOTUUID}"
  NEWBOOTUUID=`findmnt -M "${ROOTMOUNT}/boot" -n -o UUID`
  echo "New Boot UUID: ${NEWBOOTUUID}"
elif [[ ${MODE} == "MBR"  && "$ENCRYPT" != "true" ]]; then
  # get the UUID of the new root partition
  NEWROOTUUID=`findmnt -M ${ROOTMOUNT} -n -o UUID`
  echo "New Root UUID: ${NEWROOTUUID}"
else
	echo "Error: unxepected"
	exit 1
fi

#cleanup
apt-get clean

# no need to clean up what we don't copy over
# prepare exclusion file in ram at /dev/shm/
printf "/dev/*\n/proc/*\n/sys/*\n/tmp/*\n/run/*\n/mnt/*\n/media/*\n/lost+found
/swapfile\n/home/*/.thumbnails/*\n/home/*/.cache/mozilla/*
/home/*/.cache/google-chrome/*\n/home/*/.local/share/Trash/*\n/home/*/.gvfs
/var/backups/*\n/home/*/.bash_history\n/home/*/.xsession-errors*
/root/.bash_history\n/var/lib/upower/history*\n/home/*/.ssh/*\n/root/.ssh/*
/tmp/*\n/home/*/.thumbnails/*\n/home/*/.goutputstream*\n/root/.thumbnails/*
/home/*/.cache/*\n/root/.cache/*\n/var/mail/*\n/var/cache/*\n/var/log/*.gz
/var/log/*/*.gz\n/var/log/*.xz\n/var/log/*/*.xz\n/var/log/*.old
/var/log/*/*.old\n/var/log/journal/*\n/var/log/samba/*\n*~\n/root/.synaptic/log
/etc/ssh/ssh_host_*\n/root/snap\nNetworkManager.pid\n*.lock
/var/lib/NetworkManager/*.lease\n\/etc\/group\-\n\/etc\/passwd\-\n\/etc\/gshadow\-\n\/etc\/subgid\-\n\/etc\/subuid\-" \
 >> /dev/shm/rsyncexclude.tmp
# sync all the data...
echo "Replicating data to new filesystems..."
# TODO - write a better way to do this
rsync -aAXH --no-i-r --links --ignore-missing-args --info=progress2 --exclude-from=/dev/shm/rsyncexclude.tmp /* ${ROOTMOUNT}

# quick folder fix that causes apt to fail when missing
mkdir -p ${ROOTMOUNT}/var/cache/apt-show-versions
# var cache apt directory structure needs to be maintained
rsync -a -f"+ */" -f"- *" --info=progress2 /var/cache/* ${ROOTMOUNT}/var/cache/
rsync -a -f"+ */" -f"- *" --info=progress2 /var/log/* ${ROOTMOUNT}/var/log/

# delete the temporary exclude file
rm /dev/shm/rsyncexclude.tmp
# and probably a bunch of things I can kill off in the cache overall after the sync takes place - check cleanup script

if [[ "${NEWUSER}" == "true" ]]; then
	CURRUSER=`who | grep ':0' | awk '{print $1}'`
	CURRDISP=`grep ${CURRUSER} /etc/passwd | awk -F ":" '{ print $5 }' | sed -e s/,.*//`
	# modify destination with NEWUSERNAME and NEWUSERDISP on the offline system
	# also currently dangerous if we are not careful about the sed work
	mv ${ROOTMOUNT}/home/${CURRUSER} ${ROOTMOUNT}/home/${NEWUSERNAME}
	sed -i "s/autologin\-user=${CURRUSER}/autologin\-user=${NEWUSERNAME}/" ${ROOTMOUNT}/etc/lightdm/lightdm.conf
	sed -i "s/^${CURRUSER}:/${NEWUSERNAME}:/" ${ROOTMOUNT}/etc/shadow
	sed -i "s/^${CURRUSER}:/${NEWUSERNAME}:/" ${ROOTMOUNT}/etc/subgid
	sed -i "s/${CURRUSER}/${NEWUSERNAME}/g" ${ROOTMOUNT}/etc/group
	sed -i "s/${CURRUSER}/${NEWUSERNAME}/g" ${ROOTMOUNT}/etc/gshadow
	sed -i "s/^${CURRUSER} /${NEWUSERNAME} /" ${ROOTMOUNT}/etc/sudoers
	sed -i "s/^${CURRUSER}:/${NEWUSERNAME}:/" ${ROOTMOUNT}/etc/passwd
	sed -i "s/\/home\/${CURRUSER}:/\/home\/${NEWUSERNAME}:/" ${ROOTMOUNT}/etc/passwd
	sed -i "s/:${CURRDISP},/:${NEWUSERDISP},/" ${ROOTMOUNT}/etc/passwd
	sed -i "s/${CURRUSER}:/${NEWUSERNAME}:/" ${ROOTMOUNT}/etc/subuid

	# I think this needs to happen in the chroot
	#sudo -u ${NEWUSERNAME} -H dbus-launch dconf write /org/blueman/transfer/shared-path "'/home/${NEWUSERNAME}/Downloads'"

fi

# make sure the mounter named pipe is in place
#rsync -aAXx /tmp/mounter* /media${DEVICE}2/tmp/

# fix the fstab file for the replicated version before we run the cleanup script
# change the location of the swapfile - if it is a separate partition
#sed -i -e 's/^UUID.*swap.*$/\/swapfile\tnone\tswap\tsw\t0\t0/' /media${DEVICE}2/etc/fstab

# write a completely new fstab for this flash drive
echo "UUID=${NEWROOTUUID} / ext4 errors=remount-ro 0 1" > ${ROOTMOUNT}/etc/fstab

if [[ "${HIBERFIL}" == "true" ]]; then
	echo "UUID=${SWAPUUID} none swap sw 0 0" >> ${ROOTMOUNT}/etc/fstab
  #else
	#echo "/swapfile none swap sw 0 0" >> ${ROOTMOUNT}/etc/fstab
fi

if [[ ${MODE} == "EFI"  && "$ENCRYPT" == "true" ]]; then
  # boot partitions
  echo "UUID=${NEWEFIUUID} /boot/efi vfat umask=0077 0 1" >> ${ROOTMOUNT}/etc/fstab
  echo "UUID=${NEWBOOTUUID} /boot ext4 defaults 0 2" >> ${ROOTMOUNT}/etc/fstab
elif [[ ${MODE} == "EFI"  && "$ENCRYPT" != "true" ]]; then
  # boot partitions
  echo "UUID=${NEWEFIUUID} /boot/efi vfat umask=0077 0 1" >> ${ROOTMOUNT}/etc/fstab
fi

# update / create the crypttab and other config files
# also need to adjust this if we have -h or --hiberfil set to specify the swap
if [[ "${ENCRYPT}" == "true" ]]; then
    if [[ ${MODE} == "EFI" ]]; then
        NEWLUKSUUID=`lsblk -dno UUID ${DEVICE}3`
    else
        NEWLUKSUUID=`lsblk -dno UUID ${DEVICE}2`
    fi
    echo "BH11.${UNIQUE} UUID=${NEWLUKSUUID} none luks,discard" > ${ROOTMOUNT}/etc/crypttab
    echo "CRYPTROOT=target=BH11.${UNIQUE}-root,source=/dev/disk/by-uuid/${NEWLUKSUUID}" > ${ROOTMOUNT}/etc/initramfs-tools/conf.d/cryptroot
    sed -i "s/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"cryptops=target=BH11.${UNIQUE}-root,source=\/dev\/disk\/by-uuid\/${NEWLUKSUUID}\"/" ${ROOTMOUNT}/etc/default/grub

	if [[ "${HIBERFIL}" == "true" ]] ; then
		# append path to swap partition
		RESUMESTRING="RESUME=UUID=${SWAPUUID}"
		sed -i "s/^\(GRUB_CMDLINE_LINUX=\".*\)\"$/\1 ${RESUMESTRING}\"/" ${ROOTMOUNT}/etc/default/grub
	fi

else
	# if we are going crypt to clear, we need to reverse some things
	rm -f ${ROOTMOUNT}/etc/crypttab
	rm -f ${ROOTMOUNT}/etc/initramfs-tools/conf.d/cryptroot
	sed -i "s/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX=\"\"/" ${ROOTMOUNT}/etc/default/grub

	if [[ "$HIBERFIL" == "true" ]] ; then
		# append path to swap partition
		RESUMESTRING="RESUME=UUID=${SWAPUUID}"
		sed -i "s/^\(GRUB_CMDLINE_LINUX=\".*\)\"$/\1 ${RESUMESTRING}\"/" ${ROOTMOUNT}/etc/default/grub
	fi

fi

# change the location of the root partition UUID
#sed -i "s/${ROOTUUID}/${NEWROOTUUID}/" /media${DEVICE}2/etc/fstab
#sed -i "s/${BOOTUUID}/${NEWBOOTUUID}/" /media${DEVICE}2/etc/fstab
# change the location of the root parition UUID in the grub config files
sed -i "s/${ROOTUUID}/${NEWROOTUUID}/g" ${ROOTMOUNT}/boot/grub/grub.cfg
sed -i "s/$BOOTUUID}/${NEWBOOTUUID}/g" ${ROOTMOUNT}/boot/grub/grub.cfg
sed -i "s/$EFIUUID}/${NEWEFIUUID}/g" ${ROOTMOUNT}/boot/grub/grub.cfg

# disanable os-prober to prevent build os from getting added to the menu
# already disabled in source os build
#sed -i "s/GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=true/" ${ROOTMOUNT}/etc/default/grub
#sed -i "s/GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=true/" ${ROOTMOUNT}/etc/default/grub.d/50_linuxmint.cfg

# change the boot and root uuid entries in the mounter script to fix rbfstab
#sed -i "s/^BOOTUUID=.*/BOOTUUID=\"${NEWBOOTUUID}\"/" /media${DEVICE}2/usr/sbin/rbfstab
#sed -i "s/^ROOTUUID=.*/ROOTUUID=\"${NEWROOTUUID}\"/" /media${DEVICE}2/usr/sbin/rbfstab

# this file may or may not exist
if [[ -e ${ROOTMOUNT}/boot/grub/i386-pc/load.cfg ]] ; then
	sed -i "s/${ROOTUUID}/${NEWROOTUUID}/g" ${ROOTMOUNT}/boot/grub/i386-pc/load.cfg
  sed -i "s/${BOOTUUID}/${NEWBOOTUUID}/g" ${ROOTMOUNT}/boot/grub/i386-pc/load.cfg
  sed -i "s/${EFIUUID}/${NEWEFIUUID}/g" ${ROOTMOUNT}/boot/grub/i386-pc/load.cfg
fi

# update how we identify this in EFI...except it's UCS-2LE format
if [[ ${MODE} == 'EFI' ]]; then
  echo "shimx64.efi,Black Harrier 11,,This is the boot entry for Black Harrier 11" | iconv -t UCS-2LE -o /boot/efi/EFI/ubuntu/BOOTX64.CSV
  echo "shimx64.efi,Black Harrier 11,,This is the boot entry for Black Harrier 11" | iconv -t UCS-2LE -o /usr/lib/shim/BOOTX64.CSV
fi

# ... need to fix the grub install on the copy to look for the right partition
# gotta reinstall grub correctly
# bind directories

# notes while I figure this all out:
# update-initramfs does not seem to be necessary
# grub-install bootloader id breaks things
# grub needs an update because we change uuid values but don't want to include all
#    of the other partitions - need to limit!
# grubinstall -- grub update -- in chroot env
# grub-install -s option to skip filesystem probe
# add GRUB_DISABLE_OS_PROBER=true to the bottom of /etc/default/grub

mount -o rw --bind /dev ${ROOTMOUNT}/dev
mount -o rw --bind /dev/pts ${ROOTMOUNT}/dev/pts
mount -o rw --bind /proc ${ROOTMOUNT}/proc
mount -o rw --bind /sys ${ROOTMOUNT}/sys
# giving chroot access to lvm needed for the luks config?
mkdir -p ${ROOTMOUNT}/run
mount -o rw --bind /run ${ROOTMOUNT}/run

# create the temporary grub installer...for EFI64
# install lsb-release?
# grub installed on efi64 is grub-gfxpayload-lists grub-pc
#echo "apt -y install --reinstall grub-efi-amd64" > ${ROOTMOUNT}/tmp/BHGrubinstall
# also the chroot system can't get the archives or connect to the internet
# not exactly helpful here.

if [[ "${NEWUSER}" == "true" ]]; then
	# this needs to happen in the chroot
	echo "sudo -u ${NEWUSERNAME} -H dbus-launch dconf write /org/blueman/transfer/shared-path \"'/home/${NEWUSERNAME}/Downloads'\"" >> ${ROOTMOUNT}/tmp/BHGrubinstall
fi

#echo "grub-install --compress=xz --uefi-secure-boot -s ${DEVICE}" >> ${ROOTMOUNT}/tmp/BHGrubinstall
#echo "update-initramfs -u" >> ${ROOTMOUNT}/tmp/BHGrubinstall
# and fix the dns resolution issue - why does this get lost?

echo "update-initramfs -d -k all" >> ${ROOTMOUNT}/tmp/BHGrubinstall
echo "update-initramfs -c -k all" >> ${ROOTMOUNT}/tmp/BHGrubinstall
echo "update-grub" >> ${ROOTMOUNT}/tmp/BHGrubinstall
echo "grub-install --compress=xz --uefi-secure-boot -s ${DEVICE}" >> ${ROOTMOUNT}/tmp/BHGrubinstall

# cleanup old LVM entries
find ${ROOTMOUNT}/etc/lvm/ -type f ! -iname "*BH11.${UNIQUE}*" -delete

# the above line is what was taking forever because /run was missing in chroot

# update-grub installs a bunch of entries I don't really want in the boot config.
# TODO - boot loader keeps looking for the old boot uuid early in boot process which
# ultimately causes the boot process to fail. Where is this entry?
##echo "grub-install --bootloader-id ubuntu ${DEVICE}" >> /media${DEVICE}2/tmp/BHGrubinstall
chmod +x ${ROOTMOUNT}/tmp/BHGrubinstall
# chroot and install grub to the target media  - not sure why this take so long clear->luks
# looks like the update-grub line is what takes forever...because /run was missing
chroot ${ROOTMOUNT} /tmp/BHGrubinstall
# erase the temporary script
rm -v ${ROOTMOUNT}/tmp/BHGrubinstall
#grub-install --bootloader-id ubuntu ${DEVICE}

# unmount the bound directories
sync
sleep 5
# add lazy unmount failover to avoid spurious busy mountpoints
umount ${ROOTMOUNT}/run || umount -lv ${ROOTMOUNT}/run
umount ${ROOTMOUNT}/sys || umount -lv ${ROOTMOUNT}/sys
umount ${ROOTMOUNT}/proc || umount -lv ${ROOTMOUNT}/proc
umount ${ROOTMOUNT}/dev/pts || umount -lv ${ROOTMOUNT}/dev/pts
umount ${ROOTMOUNT}/dev || umount -lv ${ROOTMOUNT}/dev
sync
sleep 5

# run the cleanup script
cd ${ROOTMOUNT}
#/usr/local/sbin/bhcleanup

find ./var/log/ -type f -exec truncate -s 0 -c '{}' \;
truncate -s 0 -c ./home/*/.local/.bash_history
truncate -s 0 -c ./home/*/.local/share/recently-used.xbel
truncate -s 0 -c ./var/run/utmp
truncate -s 0 -c ./var/btmp
truncate -s 0 -c ./var/wtmp
find ./var/log/ -type f -iname '*log.[0-9]*' -delete
find ./var/log/ -type f -iname '*log.[0-9]*.gz' -delete
rm -rf ./var/tmp/*

echo Generating new host keys...
ssh-keygen -q -t dsa -f ./etc/ssh/ssh_host_dsa_key -N '' -C root@BlackHarrier11
ssh-keygen -q -t ecdsa -f ./etc/ssh/ssh_host_ecdsa_key -N '' -C root@BlackHarrier11
ssh-keygen -q -t ed25519 -f ./etc/ssh/ssh_host_ed25519_key -N '' -C root@BlackHarrier11
ssh-keygen -q -t rsa -f ./etc/ssh/ssh_host_rsa_key -N '' -C root@BlackHarrier11
ssh-keygen -l -f ./etc/ssh/ssh_host_dsa_key
ssh-keygen -l -f ./etc/ssh/ssh_host_ecdsa_key
ssh-keygen -l -f ./etc/ssh/ssh_host_ed25519_key
ssh-keygen -l -f ./etc/ssh/ssh_host_rsa_key

# skipping creation of swapfile unless specifically requested
# Assumes that /etc/fstab already has the swapfile in place
#if [[ "${HIBERFIL}" != "true" ]]; then
#	echo Creating new 512M swap file of zeroes...
#	dd bs=131072 if=/dev/zero of=./swapfile count=4096
#	chown root:root ./swapfile
#	chmod 0600 ./swapfile
#	mkswap ./swapfile
#fi

# end of cleanup process
##########
# put back missing log files - probably need to change how I do this with
# truncate to zero bytes for existing log files and deletion of older ones
# touch ${ROOTMOUNT}/var/log/wtmp
# touch ${ROOTMOUNT}/var/log/btmp

cd ${PREVDIR}


# set ESP and BOOT flags - already did this above
#parted ${DEVICE} -- set 1 boot on
#parted ${DEVICE} -- set 1 esp on

#grub-install --boot-directory=./boot -s ${DEVICE}
#grub-install -s ${DEVICE}

if [[ ${MODE} == "EFI" ]]; then
    # overwrite unallocated in the efi partition
    if [[ "${INSECURE}" != "true" ]]; then
        echo "Cleaning unallocated space in the EFI boot partition ..."
        sfill -fllzv ${ROOTMOUNT}/boot/efi/
    fi
    umount ${ROOTMOUNT}/boot/efi
fi
if [[ "${ENCRYPT}" == "true" ]] ; then
    umount ${ROOTMOUNT}/boot
fi
# strangely busy - lazy unload
umount -l ${ROOTMOUNT}

# TODO - forensic analysis of unallocated for zerofree vs sfill?
if [[ "${INSECURE}" != "true" ]]; then
    echo "Cleaning unallocated space on new / ..."
    if [[ ${MODE} == "EFI" ]]; then
	    # if encrypted, this is the /boot partition
        zerofree -v ${DEVICE}2
    elif [[ ${MODE} == "MBR" ]]; then
        zerofree -v ${DEVICE}1
    else
    	echo "Error: unxepected"
    	exit 1
    fi
fi

if [[ "${ENCRYPT}" == "true" ]] ; then
	# TODO - need a non-colliding way to specify this
    if [[ "${INSECURE}" != "true" ]]; then
        zerofree -v /dev/disk/by-uuid/${NEWROOTUUID}
    fi
fi

# cleanup local directories
#set +e
if [[ -e /media${DEVICE}3 ]] ; then
    rmdir /media${DEVICE}3
fi
if [[ -e /media${DEVICE}2 ]] ; then
    rmdir /media${DEVICE}2
fi
if [[ -e /media${DEVICE}1 ]] ; then
    rmdir /media${DEVICE}1
fi
if [[ -e /media/dev ]] ; then
    rmdir /media/dev
fi
#set -e

if [[ "${ENCRYPT}" == "true" ]] ; then
	# shut down the logical volume
	lvchange -a n /dev/BH11.${UNIQUE}/root
	# shut down the volume group
	vgchange -a n BH11.${UNIQUE}
	# shut down the physical volume
	#pvchange -a n BH11.${UNIQUE}
	# relock the encrypted drive
	cryptsetup luksClose BH11.${UNIQUE}
fi

echo
echo "Done! You may now remove your destination drive. Thank you for choosing BlackHarrier."
echo
