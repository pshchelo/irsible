#!/bin/bash

set -ex

IRSIBLE_FOR_ANSIBLE=${IRSIBLE_FOR_ANSIBLE:-true}
IRSIBLE_FOR_IRONIC=${IRSIBLE_FOR_IRONIC:-true}

if [ "$IRSIBLE_FOR_ANSIBLE" = false ]; then
    IRSIBLE_FOR_IRONIC=false
fi

WORKDIR=$(readlink -f $0 | xargs dirname)
BUILDDIR="$WORKDIR/build"
BUILD_TC_VER=6

TC=1001
STAFF=50

CHROOT_PATH="/tmp/overides:/usr/local/sbin:/usr/local/bin:/apps/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CHROOT_CMD="sudo chroot $BUILDDIR /usr/bin/env -i PATH=$CHROOT_PATH http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy"
TC_CHROOT_CMD="sudo chroot --userspec=$TC:$STAFF $BUILDDIR /usr/bin/env -i PATH=$CHROOT_PATH http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy"

echo "Building irsible:"

##############################################
# Download and Cache Tiny Core Files
##############################################

cd $WORKDIR/build_files
wget -N http://distro.ibiblio.org/tinycorelinux/${BUILD_TC_VER}.x/x86_64/release/distribution_files/corepure64.gz -O corepure64-${BUILD_TC_VER}.gz
cd $WORKDIR

# Finish here if not building for Ironic's ansible-deploy
if [ "$IRSIBLE_FOR_ANSIBLE" = false ]; then
    echo "Not building any extra packages"
    exit 0
fi

########################################################
# Build Required Dependecies in a Build Directory
########################################################

# Make directory for building in
mkdir "$BUILDDIR"

# Extract rootfs from .gz file
( cd "$BUILDDIR" && zcat $WORKDIR/build_files/corepure64-${BUILD_TC_VER}.gz | sudo cpio -i -H newc -d )

# Download Qemu-utils source
git clone git://git.qemu-project.org/qemu.git $BUILDDIR/tmp/qemu --depth=1 --branch v2.5.1

sudo cp /etc/resolv.conf $BUILDDIR/etc/resolv.conf
sudo mount --bind /proc $BUILDDIR/proc
$CHROOT_CMD mkdir /etc/sysconfig/tcedir
$CHROOT_CMD chmod a+rwx /etc/sysconfig/tcedir
$CHROOT_CMD touch /etc/sysconfig/tcuser
$CHROOT_CMD chmod a+rwx /etc/sysconfig/tcuser

mkdir $BUILDDIR/tmp/overides
cp $WORKDIR/build_files/fakeuname${BUILD_TC_VER} $BUILDDIR/tmp/overides/uname

while read line; do
    $TC_CHROOT_CMD tce-load -wci $line
done < $WORKDIR/build_files/buildreqs.lst

sudo umount $BUILDDIR/proc

# Build qemu-utils
rm -rf $WORKDIR/build_files/qemu-utils.tcz
$CHROOT_CMD /bin/sh -c "cd /tmp/qemu && ./configure --disable-system --disable-user --disable-linux-user --disable-bsd-user --disable-guest-agent && make && make install DESTDIR=/tmp/qemu-utils"
cd $WORKDIR/build_files && mksquashfs $BUILDDIR/tmp/qemu-utils qemu-utils.tcz && md5sum qemu-utils.tcz > qemu-utils.tcz.md5.txt
# Create qemu-utils.tcz.dep
echo "glib2.tcz" > qemu-utils.tcz.dep


# Download get-pip into ramdisk
( cd "$BUILDDIR/tmp" && wget https://bootstrap.pypa.io/get-pip.py )

# Create directory for python local mirror
mkdir -p "$BUILDDIR/tmp/localpip"

# install python-netifaces for ansible callback
cd $BUILDDIR/tmp
wget https://pypi.python.org/packages/18/fa/dd13d4910aea339c0bb87d2b3838d8fd923c11869b1f6e741dbd0ff3bc00/netifaces-0.10.4.tar.gz -O netifaces-0.10.4.tar.gz
tar xzf netifaces-0.10.4.tar.gz

# Build python wheels
$CHROOT_CMD python /tmp/get-pip.py
$CHROOT_CMD pip install pbr
$CHROOT_CMD pip wheel --wheel-dir /tmp/wheels setuptools
$CHROOT_CMD pip wheel --wheel-dir /tmp/wheels pip

$CHROOT_CMD sh -c "cd /tmp/netifaces-0.10.4 && python setup.py sdist --dist-dir /tmp/localpip --quiet"
$CHROOT_CMD pip wheel --no-index --pre --wheel-dir /tmp/wheels --find-links=/tmp/localpip --find-links=/tmp/wheels netifaces==0.10.4

