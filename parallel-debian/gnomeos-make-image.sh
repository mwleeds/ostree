#!/bin/sh
# -*- indent-tabs-mode: nil; -*-
# Generate a root filesystem image
#
# Copyright (C) 2011 Colin Walters <walters@verbum.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

set -e
set -x

SRCDIR=`dirname $0`
WORKDIR=`pwd`

DEPENDS="debootstrap qemu-img grubby"

for x in $DEPENDS; do
    if ! command -v $x; then
        cat <<EOF
Couldn't find required dependency $x
EOF
        exit 1
    fi
done

if test $(id -u) != 0; then
    cat <<EOF
This script must be run as root.
EOF
    exit 1
fi

if test -z "${OSTREE}"; then
    OSTREE=`command -v ostree || true`
fi
if test -z "${OSTREE}"; then
    cat <<EOF
ERROR:
Couldn't find ostree; you can set the OSTREE environment variable to point to it
e.g.: OSTREE=~user/checkout/ostree/ostree $0
EOF
    exit 1
fi

if test -z "$DRACUT"; then
    if ! test -d dracut; then
        cat <<EOF
Checking out and patching dracut...
EOF
        git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
        (cd dracut; git am $SRCDIR/0001-Support-OSTree.patch)
        (cd dracut; make)
    fi
    DRACUT=`pwd`/dracut/dracut
fi

case `uname -p` in
    x86_64)
        ARCH=amd64
        ;;
    *)
        echo "Unsupported architecture"
        ;;
esac;

DEBTARGET=wheezy

INITRD_MOVE_MOUNTS="dev proc sys"
TOPROOT_BIND_MOUNTS="boot home root tmp"
OSTREE_BIND_MOUNTS="var"
MOVE_MOUNTS="selinux mnt media"
READONLY_BIND_MOUNTS="bin etc lib lib32 lib64 sbin usr"

OBJ=debootstrap-$DEBTARGET
if ! test -d ${OBJ} ; then
    echo "Creating $DEBTARGET.img"
    mkdir -p ${OBJ}.tmp
    debootstrap --download-only --arch $ARCH $DEBTARGET ${OBJ}.tmp
    mv ${OBJ}.tmp ${OBJ}
fi

OBJ=$DEBTARGET-fs
if ! test -d ${OBJ}; then
    rm -rf ${OBJ}.tmp
    mkdir ${OBJ}.tmp

    for d in debootstrap-$DEBTARGET/var/cache/apt/archives/*.deb; do
        rm -rf work; mkdir work
        (cd work && ar x ../$d && tar -x -z -C ../${OBJ}.tmp -f data.tar.gz)
    done

    (cd ${OBJ}.tmp;
        mkdir ostree
        mkdir ostree/repo
        mkdir ostree/gnomeos-origin
        for d in $INITRD_MOVE_MOUNTS $TOPROOT_BIND_MOUNTS; do
            mkdir -p ostree/gnomeos-origin/$d
            chmod --reference $d ostree/gnomeos-origin/$d
        done
        for d in $OSTREE_BIND_MOUNTS; do
            mkdir -p ostree/gnomeos-origin/$d
            chmod --reference $d ostree/gnomeos-origin/$d
            mv $d ostree
        done
        for d in $READONLY_BIND_MOUNTS $MOVE_MOUNTS; do
            if test -d $d; then
                mv $d ostree/gnomeos-origin
            fi
        done

        $OSTREE init --repo=ostree/repo
        (cd ostree/gnomeos-origin; find . '!' -type p | grep -v '^.$' | $OSTREE commit -s 'Initial import' --repo=../repo --from-stdin)
    )
    if test -d ${OBJ}; then
        mv ${OBJ} ${OBJ}.old
    fi
    mv ${OBJ}.tmp ${OBJ}
    rm -rf ${OBJ}.old
fi

# TODO download source for above
# TODO download build dependencies for above

OBJ=gnomeos-fs
if ! test -d ${OBJ}; then
    rm -rf ${OBJ}.tmp
    cp -al $DEBTARGET-fs ${OBJ}.tmp
    (cd ${OBJ}.tmp;

        cp ${SRCDIR}/debian-setup.sh ostree/gnomeos-origin/
        chroot ostree/gnomeos-origin ./debian-setup.sh
        rm ostree/gnomeos-origin/debian-setup.sh
        (cd ostree/gnomeos-origin; find . '!' -type p | grep -v '^.$' | $OSTREE commit -s 'Run debian-setup.sh' --repo=../repo --from-stdin)

        # This is the name for the real rootfs, not the chroot
        (cd ostree/gnomeos-origin;
            mkdir sysroot;
            $OSTREE commit -s 'Add sysroot' --repo=../repo --add=sysroot)

        (cd ostree;
            rev=$($OSTREE rev-parse --repo=repo master)
            $OSTREE checkout --repo=repo ${rev} gnomeos-${rev}
            $OSTREE run-triggers --repo=repo gnomeos-${rev}
            ln -s gnomeos-${rev} current
            rm -rf gnomeos-origin)
    )
    if test -d ${OBJ}; then
        mv ${OBJ} ${OBJ}.old
    fi
    mv ${OBJ}.tmp ${OBJ}
    rm -rf ${OBJ}.old
fi

cp ${SRCDIR}/ostree_switch_root ${WORKDIR}

kv=`uname -r`
kernel=/boot/vmlinuz-${kv}
if ! test -f "${kernel}"; then
    cat <<EOF
Failed to find ${kernel}
EOF
fi

OBJ=gnomeos-initrd.img
VOBJ=gnomeos-initrd-${kv}.img
if ! test -f ${OBJ}; then
    rm -f ${OBJ}.tmp ${VOBJ}.tmp
    $DRACUT -l -v --include `pwd`/ostree_switch_root /sbin/ostree_switch_root ${VOBJ}.tmp
    mv ${VOBJ}.tmp ${VOBJ}
    ln -sf ${VOBJ} gnomeos-initrd.img
fi
