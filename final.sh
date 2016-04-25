#!/bin/bash

set -ex
WORKDIR=$(readlink -f $0 | xargs dirname)
FINALDIR="$WORKDIR/final"

IRSIBLE_SSH_KEY=${IRSIBLE_SSH_KEY:-$WORKDIR/irsible_key.pub}
IRSIBLE_FOR_ANSIBLE=${IRSIBLE_FOR_ANSIBLE:-true}
IRSIBLE_FOR_IRONIC=${IRSIBLE_FOR_IRONIC:-true}

if [ "$IRSIBLE_FOR_ANSIBLE" = false ]; then
    IRSIBLE_FOR_IRONIC=false
fi

TC=1001
STAFF=50

CHROOT_PATH="/tmp/overides:/usr/local/sbin:/usr/local/bin:/apps/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CHROOT_CMD="sudo chroot $FINALDIR /usr/bin/env -i PATH=$CHROOT_PATH http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy"
TC_CHROOT_CMD="sudo chroot --userspec=$TC:$STAFF $FINALDIR /usr/bin/env -i PATH=$CHROOT_PATH http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy"

echo "Finalising irsible:"

cd $WORKDIR/build_files
rm -f corepure64.gz vmlinuz64
wget -N http://distro.ibiblio.org/tinycorelinux/7.x/x86_64/release/distribution_files/corepure64.gz
wget -N http://distro.ibiblio.org/tinycorelinux/7.x/x86_64/release/distribution_files/vmlinuz64
cd $WORKDIR

sudo -v

if [ -d "$FINALDIR" ]; then
    sudo rm -rf "$FINALDIR"
fi

mkdir "$FINALDIR"

# Extract rootfs from .gz file
( cd "$FINALDIR" && zcat $WORKDIR/build_files/corepure64.gz | sudo cpio -i -H newc -d )

#####################################
# Setup Final Dir
#####################################

sudo cp $FINALDIR/etc/resolv.conf $FINALDIR/etc/resolv.conf.old
sudo cp /etc/resolv.conf $FINALDIR/etc/resolv.conf

mkdir -p $FINALDIR/tmp/builtin/optional
$CHROOT_CMD chown -R tc.staff /tmp/builtin
$CHROOT_CMD chmod -R a+w /tmp/builtin
$CHROOT_CMD ln -sf /tmp/builtin /etc/sysconfig/tcedir
echo "tc" | $CHROOT_CMD tee -a /etc/sysconfig/tcuser

# Mount /proc for chroot commands
sudo mount --bind /proc $FINALDIR/proc
# Fake uname to get correct dependencies
mkdir $FINALDIR/tmp/overides                                                                                                                                                                                    
cp $WORKDIR/build_files/fakeuname7 $FINALDIR/tmp/overides/uname

# Install and configure bare minimum for SSH access
$TC_CHROOT_CMD tce-load -wi openssh
# Configure OpsnSSH
$CHROOT_CMD cp /usr/local/etc/ssh/sshd_config_example /usr/local/etc/ssh/sshd_config || $CHROOT_CMD cp /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config
echo "PasswordAuthentication no" | $CHROOT_CMD tee -a /usr/local/etc/ssh/sshd_config
$CHROOT_CMD /usr/local/etc/init.d/openssh keygen
echo "HostKey /usr/local/etc/ssh/ssh_host_rsa_key" | $CHROOT_CMD tee -a /usr/local/etc/ssh/sshd_config
echo "HostKey /usr/local/etc/ssh/ssh_host_dsa_key" | $CHROOT_CMD tee -a /usr/local/etc/ssh/sshd_config


# setup user and SSH keys
$CHROOT_CMD mkdir -p /home/tc
$CHROOT_CMD chown -R tc.staff /home/tc
$TC_CHROOT_CMD mkdir -p /home/tc/.ssh
sudo cp $IRSIBLE_SSH_KEY $FINALDIR/home/tc/.ssh/authorized_keys
$CHROOT_CMD chown tc.staff /home/tc/.ssh/authorized_keys
$TC_CHROOT_CMD chmod 600 /home/tc/.ssh/authorized_keys 

if [ "$IRSIBLE_FOR_ANSIBLE" = true ]; then
    # install Python
    $TC_CHROOT_CMD tce-load -wi python
    # Symlink Python to place expected by Ansible by default
    $CHROOT_CMD ln -s /usr/local/bin/python /usr/bin/python
    if [ "$IRSIBLE_FOR_IRONIC" = true ]; then
        # install other packages
        while read line; do
            $TC_CHROOT_CMD tce-load -wi $line
        done < $WORKDIR/build_files/finalreqs.lst
        # install compiled qemu-utils
        cp $WORKDIR/build_files/qemu-utils.* $FINALDIR/tmp/builtin/optional
        echo "qemu-utils.tcz" | $TC_CHROOT_CMD tee -a /tmp/builtin/onboot.lst
        # install python-requests - used in streaming download of raw images
        cd $FINALDIR/tmp
        wget https://github.com/kennethreitz/requests/archive/v2.9.1.tar.gz -O requests-2.9.1.tar.gz
        tar xzf requests-2.9.1.tar.gz
        $CHROOT_CMD sh -c "cd /tmp/requests-2.9.1 && python setup.py install"
        sudo rm -rf $FINALDIR/tmp/requests-2.9.1*
        # save some MB, leave only compiled python code
        sudo find $FINALDIR/usr/local/lib/python2.7/site-packages/requests/ -type f -name "*.py" -exec rm {} +
    fi
fi

# Unmount /proc and clean up everything
sudo umount $FINALDIR/proc
sudo umount $FINALDIR/tmp/tcloop/*
sudo rm -rf $FINALDIR/tmp/tcloop
sudo rm -rf $FINALDIR/usr/local/tce.installed
sudo mv $FINALDIR/etc/resolv.conf.old $FINALDIR/etc/resolv.conf
sudo rm $FINALDIR/etc/sysconfig/tcuser
sudo rm $FINALDIR/etc/sysconfig/tcedir
sudo rm -rf $FINALDIR/tmp/overides

# Copy bootlocal.sh to opt
sudo cp "$WORKDIR/build_files/bootlocal.sh" "$FINALDIR/opt/."

# Disable ZSwap
sudo sed -i '/# Main/a NOZSWAP=1' "$FINALDIR/etc/init.d/tc-config"

###############################
# Pack everything back to image
###############################

# Allow an extension to be added to the generated files by specifying
# $BRANCH_PATH e.g. export BRANCH_PATH=master results in irsible-master.gz etc
branch_ext=''
if [ -n "$BRANCH_PATH" ]; then
    branch_ext="-$BRANCH_PATH"
fi

# Rebuild build directory into gz file
#( cd "$FINALDIR" && sudo find | sudo cpio -o -H newc | gzip -9 > "$WORKDIR/tinyipa${branch_ext}.gz" )
( cd "$FINALDIR" && sudo find | sudo cpio -o -H newc | gzip -9 > "$WORKDIR/irsible${branch_ext}.gz" )

# Copy vmlinuz to new name
cp "$WORKDIR/build_files/vmlinuz64" "$WORKDIR/irsible${branch_ext}.vmlinuz"

# Create tar.gz containing irsible files
cd $WORKDIR
tar czf irsible${branch_ext}.tar.gz irsible${branch_ext}.gz irsible${branch_ext}.vmlinuz
