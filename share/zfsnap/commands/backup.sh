#!/bin/sh

# This file is licensed under the BSD-3-Clause license.
# See the AUTHORS and LICENSE files for more information.

PREFIX=''           # Default prefix
INTERMEDIARY='-i'   # Default intermediary

# FUNCTIONS
Help() {
    cat << EOF
${0##*/} v${VERSION}

Syntax:
${0##*/} backup [ options ] zpool/filesystem [host:]zpool/filesystem

OPTIONS:
  -h           = Print this help and exit
  -I           = Send all intermediary snapshots
  -n           = Dry-run. Perform a trial run with no actions actually performed
  -p prefix    = Prefix to use when backuping snapshots
  -s           = Skip pools that are resilvering
  -S           = Skip pools that are scrubbing
  -v           = Verbose output

LINKS:
  website:          http://www.zfsnap.org
  repository:       https://github.com/zfsnap/zfsnap
  bug tracking:     https://github.com/zfsnap/zfsnap/issues

EOF
    Exit 0
}

# get options, process snapshot backup
OPTIND=1
while getopts :hInp:sSv OPT; do
    case "$OPT" in
        h) Help;;
        I) INTERMEDIARY='-I';;
        n) DRY_RUN='true';;
        p) PREFIX=$OPTARG;;
        s) PopulateSkipPools 'resilver';;
        S) PopulateSkipPools 'scrub';;
        v) VERBOSE='true';;

        :) Fatal "Option -${OPTARG} requires an argument.";;
       \?) Fatal "Invalid option: -${OPTARG}.";;
    esac
done

# discard all arguments processed thus far
shift $(($OPTIND - 1))

# backup
if [ "$#" -eq 2 ]; then
    FSExists "$1" || Fatal "'$1' does not exist!"
    ! SkipPool "$1" && exit

    LOCAL_ZFS_DATASET="$1"

    REMOTE_ZFS_DATASET="${2##*:}"
    REMOTE_HOST="${2%:*}"

    if [ "$REMOTE_ZFS_DATASET" = "$REMOTE_HOST" ]; then
        REMOTE_HOST=""
        REMOTE_ZFS_CMD="$ZFS_CMD"
    else
        REMOTE_ZFS_CMD="ssh $REMOTE_HOST $ZFS_CMD"
    fi

    # full backup
    if ! $REMOTE_ZFS_CMD list $REMOTE_ZFS_DATASET > /dev/null 2>&1; then
        LOCAL_ZFS_SNAPSHOTS=`$ZFS_CMD list -H -o name -s creation -t snapshot -r $LOCAL_ZFS_DATASET`
        [ -z "$LOCAL_ZFS_SNAPSHOTS" ] && Fatal "No local snapshots exist!"
        for LOCAL_ZFS_SNAPSHOT in $LOCAL_ZFS_SNAPSHOTS; do
            if [ -n "$PREFIX" ]; then
                [ -z "${LOCAL_ZFS_SNAPSHOT##*$PREFIX*}" ] || continue
            fi

            TrimToDate $LOCAL_ZFS_SNAPSHOT || continue
            TrimToTTL $LOCAL_ZFS_SNAPSHOT || continue
            LATEST_LOCAL_ZFS_SNAPSHOT=$LOCAL_ZFS_SNAPSHOT
        done
        [ -z $LATEST_LOCAL_ZFS_SNAPSHOT ] && Fatal "No matching local snapshot exists!"

        ZFS_FULL_BACKUP="$ZFS_CMD send -L -e $LATEST_LOCAL_ZFS_SNAPSHOT | $REMOTE_ZFS_CMD receive $REMOTE_ZFS_DATASET"

        if IsFalse "$DRY_RUN"; then
            if $ZFS_CMD send -L -e $LATEST_LOCAL_ZFS_SNAPSHOT 2>/dev/null | $REMOTE_ZFS_CMD receive $REMOTE_ZFS_DATASET 2>/dev/null; then
                IsTrue $VERBOSE && printf '%s ... DONE\n' "$ZFS_FULL_BACKUP"
            else
                IsTrue $VERBOSE && printf '%s ... FAIL\n' "$ZFS_FULL_BACKUP"
            fi
        else
            printf '%s\n' "$ZFS_FULL_BACKUP"
        fi
    # incrementall backup
    else
        REMOTE_ZFS_SNAPSHOTS=`$REMOTE_ZFS_CMD list -H -o name -s creation -t snapshot -r $REMOTE_ZFS_DATASET`
        [ -z "$REMOTE_ZFS_SNAPSHOTS" ] && Fatal "No remote snapshots exist!"
        for REMOTE_ZFS_SNAPSHOT in $REMOTE_ZFS_SNAPSHOTS; do
            TrimToDate $REMOTE_ZFS_SNAPSHOT || continue
            TrimToTTL $REMOTE_ZFS_SNAPSHOT || continue
            LATEST_REMOTE_ZFS_SNAPSHOT=$REMOTE_ZFS_SNAPSHOT
        done
        [ -z $LATEST_REMOTE_ZFS_SNAPSHOT ] && Fatal "No matching remote snapshot exist!"
        TrimToDate "$LATEST_REMOTE_ZFS_SNAPSHOT" && LATEST_REMOTE_DATE=$RETVAL

        LOCAL_ZFS_SNAPSHOTS=`$ZFS_CMD list -H -o name -s creation -t snapshot -r $LOCAL_ZFS_DATASET`
        [ -z "$LOCAL_ZFS_SNAPSHOTS" ] && Fatal "No local snapshots exist!"
        for LOCAL_ZFS_SNAPSHOT in $LOCAL_ZFS_SNAPSHOTS; do
            if [ -n "$PREFIX" ]; then
                [ -z "${LOCAL_ZFS_SNAPSHOT##*$PREFIX*}" ] || continue
            fi

            TrimToDate $LOCAL_ZFS_SNAPSHOT || continue
            TrimToTTL $LOCAL_ZFS_SNAPSHOT || continue
            LATEST_LOCAL_ZFS_SNAPSHOT=$LOCAL_ZFS_SNAPSHOT
        done
        [ -z "$LATEST_LOCAL_ZFS_SNAPSHOT" ] && Fatal "No matching local snapshot exists!"
        TrimToDate "$LATEST_LOCAL_ZFS_SNAPSHOT" && LATEST_LOCAL_DATE=$RETVAL

        GreaterDate "$LATEST_REMOTE_DATE" "$LATEST_LOCAL_DATE"
        if [ $? -eq 1 ]; then
            LATEST_REMOTE_ZFS_SNAPSHOT_NAME="${LATEST_REMOTE_ZFS_SNAPSHOT##*@}"
            PREV_LOCAL_ZFS_SNAPSHOT="${LOCAL_ZFS_DATASET}@${LATEST_REMOTE_ZFS_SNAPSHOT_NAME}"

            $ZFS_CMD list $PREV_LOCAL_ZFS_SNAPSHOT > /dev/null 2>&1 || Fatal "$PREV_LOCAL_ZFS_SNAPSHOT does not exist!"

            ZFS_INC_BACKUP="$ZFS_CMD send -L -e $INTERMEDIARY $PREV_LOCAL_ZFS_SNAPSHOT $LATEST_LOCAL_ZFS_SNAPSHOT | $REMOTE_ZFS_CMD receive $REMOTE_ZFS_DATASET"
            if IsFalse "$DRY_RUN"; then
                if $ZFS_CMD send -L -e $INTERMEDIARY $PREV_LOCAL_ZFS_SNAPSHOT $LATEST_LOCAL_ZFS_SNAPSHOT 2>/dev/null | ${REMOTE_ZFS_CMD} receive -F $REMOTE_ZFS_DATASET 2>/dev/null; then
                    IsTrue $VERBOSE && printf '%s ... DONE\n' "$ZFS_INC_BACKUP"
                else
                    IsTrue $VERBOSE && printf '%s ... FAIL\n' "$ZFS_INC_BACKUP"
                fi
            else
                printf '%s\n' "$ZFS_INC_BACKUP"
            fi
        fi
    fi
fi
