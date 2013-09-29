#!/bin/bash
# Copyleft Christian Nilsson
# Please do what you want! Use on your own risk and all that!
#
# This script partitions ${IDEV}, creates filesystem and installs gentoo.
# Everything is done including the first reboot (just before reboot it will stop and let you edit the network configuration)
#
# root password will be set to SET_PASS parameter or "password" if not given
# ssh server will be started on the live medium directly after the password have been set.
#
# Partitioning will be 100MB boot(ext2) 4GB Swap and the rest root(ext4) on /dev/sda
#
# Hostname will be set to the same as the host
# Keyboard layout will be configured to be swedish (sv-latin1) and timezone Europe/Stockholm (and ntp.se will be used as a timeserver)
#

# Make sure our root mountpoint exists
hostname fang
mkdir -p /mnt/gentoo

PREFILE=$1
IDEV=/dev/sda
FSTABDEV=${IDEV}

if [ "$(hostname)" == "livecd" ]; then
  echo Change hostname before you continue since it will be used for the created host.
  exit 1
fi
#IF NOT SET_PASS is set then the password will be "password"
SET_PASS=${SET_PASS:-password}
/etc/init.d/sshd start
echo -e "${SET_PASS}\n${SET_PASS}\n" | passwd

setterm -blank 0
set -x

#Create a 100MB boot 4GB Swap and the rest root on ${IDEV}
echo "
p
o
n
p


+100M
t
L
83
n
p


+1G
t
2
82
n
p



t
3
83
n
p


w
" | fdisk ${IDEV} || exit 1

#we should detect and use md if we multiple disks with same size...
#sfdisk -d ${IDEV} | sfdisk --force /dev/sdb || exit 1
#for a in /dev/md*; do mdadm -S $a; done

#mdadm --help
#mdadm -C --help

#mdadm -Cv /dev/md1 -l1 -n2 /dev/sd[ab]1 --metadata=0.90 || exit 1
#mdadm -Cv /dev/md3 -l1 -n2 /dev/sd[ab]3 --metadata=0.90 || exit 1
#mdadm -Cv /dev/md4 -l4 -n3 /dev/sd[ab]4 missing --metadata=0.90 || exit 1

mkswap -L swap0 ${IDEV}2 || exit 1
#mkswap -L swap1 /dev/sdb2 || exit 1

swapon -p1 ${IDEV}2 || exit 1

mkfs.ext2 ${IDEV}1 || exit 1
mkfs.ext4 ${IDEV}3 || exit 1

#cat /proc/mdstat

mount ${IDEV}3 /mnt/gentoo -o discard,noatime || exit 1
mkdir /mnt/gentoo/boot || exit 1
mount ${IDEV}1 /mnt/gentoo/boot || exit 1

cd /mnt/gentoo || exit 1
#cleanup in case of previous try...
#[ -f *.bz2 ] && rm *.bz2
#FILE=$(wget -q http://distfiles.gentoo.org/releases/amd64/current-stage3/ -O - | grep -o -e "stage3-amd64-\w*.tar.bz2" | uniq)
#[ -z "$FILE" ] && exit 1
#download latest stage file.
#wget -c http://distfiles.gentoo.org/releases/amd64/current-stage3/$FILE -O $PREFILE/$FILE || exit 1
mkdir -p usr
tar -xjpf ${PREFILE}/stage3-*bz2
#time tar -xjpf ${PREFILE}/${FILE} &

#(wget http://distfiles.gentoo.org/releases/snapshots/current/portage-latest.tar.bz2 && \
# cd usr && \
# time tar -xjf ../portage-latest.tar.bz2) || exit 1
#wait
cd usr && time tar -xjf $PREFILE/portage-latest.tar.bz2
mkdir portage/distfiles
mount --bind $PREFILE/distfiles/ portage/distfiles

cd ../
cp /etc/resolv.conf etc
# make sure we are done with root unpack...

echo "# Set to the hostname of this machine
hostname=\"$(hostname)\"
" > etc/conf.d/hostname
#change fstab to match disk layout
echo -e "
${FSTABDEV}1		/boot		ext2		noatime	        1 2
${FSTABDEV}3		/		ext4		discard,noatime	0 1
LABEL=swap0		none		swap		sw		0 0

none			/var/tmp	tmpfs		size=6G,nr_inodes=1M 0 0
" >> etc/fstab
sed -i '/\/dev\/BOOT.*/d' etc/fstab
sed -i '/\/dev\/ROOT.*/d' etc/fstab
sed -i '/\/dev\/SWAP.*/d' etc/fstab
for p in sys dev proc; do mount /$p $p -o bind; done  || exit 1

MAKECONF=etc/portage/make.conf
[ ! -f $MAKECONF ] && [ -f etc/make.conf ] && MAKECONF=etc/make.conf
echo $MAKECONF

#Updating Makefile
echo >> $MAKECONF
echo "# add valid -march= to CFLAGS" >> $MAKECONF
echo "MAKEOPTS=\"-j4\"" >> $MAKECONF
echo "FEATURES=\"parallel-fetch\"" >> $MAKECONF
echo "USE=\"\${USE} -X python qemu gnutls idn iproute2 logrotate snmp\"" >> $MAKECONF
echo "PYTHON_TARGETS=\"python2_7\"" >> $MAKECONF
echo "ACCEPT_KEYWORDS=\"~amd64\"" >> $MAKECONF
echo "SYNC=\"rsync://mirrors.ustc.edu.cn/gentoo-portage\"" >> $MAKECONF


grep -q autoinstall /proc/cmdline || nano $MAKECONF

echo "keymap=\"us\"" >> etc/conf.d/keymaps

echo "rc_logger=\"YES\"" >> etc/rc.conf
echo "rc_sys=\"\"" >> etc/rc.conf

echo "
dhcp_eth0=\"nodns nontp nonis nosendhost\"
config_eth0=\"dhcp\"

" >> etc/conf.d/net

#generate chroot script
cat > chrootstart.sh << EOF
#!/bin/bash
env-update
source /etc/profile
echo -e "${SET_PASS}\n${SET_PASS}\n" | passwd
set -x
#rm *.bz2
mount /var/tmp

[ -d /etc/portage/package.keywords ] || mkdir -p /etc/portage/package.keywords
grep -q gentoo-sources /etc/portage/package.keywords/* || echo sys-kernel/gentoo-sources > /etc/portage/package.keywords/kernel
touch /etc/portage/package.use
# The old udev rules are removed and now replaced with the PredictableNetworkInterfaceNames madness instead, and no use flags any more.
#   Will have to revert to the old way of removing the files on boot/shutdown, and just hope they don't change the naming.
#   Looks like udev is just getting worse and worse
#   or maybe we should just mask anything newer then 171, keeping -rule_generator for that case.
grep -q sys-fs/udev /etc/portage/package.use || echo sys-fs/udev hwdb gudev keymap -rule_generator >> /etc/portage/package.use
#snmp support in current apcupsd is buggy

#start out with being up2date
#we expect that this can fail
mkdir -p /etc/portage/repos.conf
echo -e "
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /usr/portage
sync-type = rsync
#sync-uri = rsync://rsync.gentoo.org/gentoo-portage
sync-uri = rsync://mirrors.ustc.edu.cn/gentoo-portage
" > /etc/portage/repos.conf/gentoo

eselect python set 1
eselect profile set 7
echo "en_US.UTF8 UTF-8" > /etc/locale.gen

time emerge --sync
time emerge -uv -j4 gentoo-sources portage python-updater gentoolkit openrc perl
perl-cleaner all
## XXX, appending more config from behind
cd /usr/src/linux
#getting a base kernel config
wget https://raw.github.com/nusgnaf/Gentoo-HAI/master/minimal.conf -O .config

cd /etc
cp /usr/share/zoneinfo/Asia/Shanghai localtime
echo 'Asia/Shanghai' > timezone

# fetch all packages first
time emerge -uvDN -f world
time emerge -uvDN -j4 world
etc-update --automode -5
time python-updater -v -- -j4 || bash
time revdep-rebuild -vi -- -j4
etc-update --automode -5

time emerge -uv -j8 mlocate iproute2 dhcp pciutils usbutils syslog-ng vixie-cron lsof || bash
time emerge -uv -j8 iptables grub || bash
lspci
#rerun make sure up2date
time emerge -uvDN -j4 world || bash
etc-update --automode -5
time python-updater -v -- -j4 || bash
time revdep-rebuild -vi -- -j4
etc-update --automode -5

cd /usr/src/linux
echo "
#iotop stuff
CONFIG_TASK_IO_ACCOUNTING=y
CONFIG_TASK_DELAY_ACCT=y
CONFIG_TASKSTATS=y
CONFIG_VM_EVENT_COUNTERS=y
#qemu kvm_stat need
CONFIG_DEBUG_FS=y

# use old vesa, vga= mode
CONFIG_FB_VESA=y
# and make uvesafb a module instead
CONFIG_FB_UVESA=m

" >> .config

echo "x
y
" | make menuconfig
time make -j16 bzImage modules && make modules_install install
ls -lh /boot
cd /boot
ln -s vmlinuz-* vmlinuz && cd /usr/src/linux && make install
ls -lh /boot
echo "
# added auto fix timeout ?
timeout 3
title Gentoo
root (hd0,0)
# video=uvesafb:1024x768-32 is not stable on ex intel integrated gfx
kernel /vmlinuz root=${FSTABDEV}3 ro rootfstype=ext4 panic=30 vga=791" >> /boot/grub/grub.conf
echo "root (hd0,0)
setup (hd0)
quit
" | grub

touch /lib64/rc/init.d/softlevel
dispatch-conf

#todo fix with sed ... but virtual machine dont save clock ;)
#touch /lib64/rc/init.d/softlevel
#/etc/init.d/hwclock save
date
sleep 3
sed -i 's/^c1:12345:respawn:\/sbin\/agetty .* tty1 linux\$/& --noclear/' /etc/inittab || bash
cd /etc/init.d
ln -s net.lo net.eth0
rc-update add syslog-ng default
rc-update add vixie-cron default
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
rc-update add sshd default
/etc/init.d/sshd gen_keys

# Start creating fix script
echo # Remove udev rules that make network interface names compleatly unpredictable and unmanagable. > /etc/local.d/remove.net.rules.start
echo setterm -blank 0 >> /etc/local.d/remove.net.rules.start
echo rm -rf /lib/udev/rules.d/80-net-name-slot.rules >> /etc/local.d/remove.net.rules.start

# Make it executable, and run also on shutdown
chmod a+x /etc/local.d/remove.net.rules.start
ln -fs /etc/local.d/remove.net.rules.start ln -fs /etc/local.d/remove.net.rules.stop
rc-update add local default
# run it now and add clean exit (rm will fail if there is no file so always exit with ok)
sh /etc/local.d/remove.net.rules.start
echo exit 0 >> /etc/local.d/remove.net.rules.start

sleep 5 || bash

# fix problem with apcupsd...
[ -d /run/lock ] || mkdir /run/lock
emerge -uv -j4 dev-vcs/git subversion iotop iftop nmap socat || bash

nano /etc/conf.d/net
rc-update add net.eth0 default
sleep 5 || bash

EOF
chmod a+x chrootstart.sh

#chroot . ./chrootstart.sh
#rm chrootstart.sh

#rm -rf var/tmp/*
#umount var/tmp
#rm -rf usr/portage/distfiles
#umount *
#cd /
#umount /mnt/gentoo/usr/portage/distfiles || exit 1
#umount /mnt/gentoo  || exit 1
#reboot


