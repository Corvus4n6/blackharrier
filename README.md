# Black Harrier Linux v11

## Description

This latest iteration of a Linux distro that has taken many forms over the past 17+ years, [Black Harrier Linux](https://blackharrier.net) was developed to be a digital Jack-of-all-trades, initially focusing on IT support and system administration, later transitioning to supporting forensics / incident response (DFIR) and related technical analysis.

Based on [Linux Mint](https://linuxmint.com/) 64-bit MATE-Desktop, Black Harrier is designed to be a handy live OS that you can keep on your key fob for ad-hoc use or install on the hardware of your choice to make a Linux desktop analysis machine. Features include:

* Live Booting - Born out of a need to live-boot a computer and access data without worrying about the computer making things difficult.

* Extensible - Nothing is permanent except change. The ability to add tools or make persistent configuration changes to the live system was the driving factor for avoiding immutable formats like ISO files.

* Replication - Sometimes, you need more than one copy of a boot disk. The bhreplicate script will quickly make a copy of the complete live system to new target media.

* Forensically Safe(r) - Whether making a machine image itself or borrowing a laptop from a friend, drive auto-mount and hardware clock updates are disabled in 'portable' mode.

Note: There is **no** software write-block installed. You can modify or destroy data if you take actions to do so either intentionally or accidentally. Use this distro with care and be thoughtful. You are responsible for your actions and any data destruction resulting from using Black Harrier. As the end user, you alone are responsible for testing and validating this distribution.

## Installation

Start with a base installation of Linux Mint, 64-bit with Mate-Desktop, (confirmed to work with release 22, aka Wilma), and apply all updates. After rebooting, open a terminal window, and type or copy/paste:

```yaml
sudo apt -y install git
git clone https://github.com/Corvus4n6/blackharrier.git
cd blackharrier
sudo bash install.sh
```

Designed as a live-boot system, a 'portable' installation will delete the passwords for **all** users. This is the default behavior and is implemented to make distributing a live distro easier.

Running this install script on your existing Linux system is not recommended and will likely result in bad things, like data destruction and loss of access.

## Pre-built Bootable Images

Pre-built disk image and virtual machine OVA files are available for download at the [Black Harrier Website](https://blackharrier.net)
