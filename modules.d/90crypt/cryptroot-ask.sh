#!/bin/sh
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin
NEWROOT=${NEWROOT:-"/sysroot"}

# do not ask, if we already have root
[ -f $NEWROOT/proc ] && exit 0

# check if destination already exists
[ -b /dev/mapper/$2 ] && exit 0

# we already asked for this device
[ -f /tmp/cryptroot-asked-$2 ] && exit 0

# load dm_crypt if it is not already loaded
[ -d /sys/module/dm_crypt ] || modprobe dm_crypt

. /lib/dracut-crypt-lib.sh

# default luksname - luks-UUID
luksname=$2

# if device name is /dev/dm-X, convert to /dev/mapper/name
if [ "${1##/dev/dm-}" != "$1" ]; then
    device="/dev/mapper/$(dmsetup info -c --noheadings -o name "$1")"
else
    device="$1"
fi

# TODO: improve to support what cmdline does
if [ -f /etc/crypttab ] && getargbool 1 rd.luks.crypttab -n rd_NO_CRYPTTAB; then
    while read name dev rest; do
        # ignore blank lines and comments
        if [ -z "$name" -o "${name#\#}" != "$name" ]; then
            continue
        fi

        # UUID used in crypttab
        if [ "${dev%%=*}" = "UUID" ]; then
            if [ "luks-${dev##UUID=}" = "$2" ]; then
                luksname="$name"
                break
            fi
            
        # path used in crypttab
        else
            cdev=$(readlink -f $dev)
            mdev=$(readlink -f $device)
            if [ "$cdev" = "$mdev" ]; then
                luksname="$name"
                break
            fi
        fi
    done < /etc/crypttab
    unset name dev rest
fi

#
# Open LUKS device
#

info "luksOpen $device $luksname"

if [ -n "$(getarg rd.luks.key)" ]; then
    if tmp=$(getkey /tmp/luks.keys $device); then
        keydev="${tmp%%:*}"
        keypath="${tmp#*:}"
    else
        info "No key found for $device.  Will try later."
        initqueue --unique --onetime --settled \
            --name cryptroot-ask-$luksname \
            $(command -v cryptroot-ask) "$@"
        exit 0
    fi
    unset tmp

    info "Using '$keypath' on '$keydev'"
    readkey "$keypath" "$keydev" "$device" \
        | cryptsetup -d - luksOpen "$device" "$luksname"
    unset keypath keydev
else
    luks_open="$(command -v cryptsetup) luksOpen"
    ask_for_password --ply-tries 5 \
        --ply-cmd "$luks_open -T1 $device $luksname" \
        --ply-prompt "Password ($device)" \
        --tty-tries 1 \
        --tty-cmd "$luks_open -T5 $device $luksname"
    unset luks_open
fi

unset device luksname

# mark device as asked
>> /tmp/cryptroot-asked-$2

udevsettle

exit 0
