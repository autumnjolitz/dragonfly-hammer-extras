#!/usr/bin/env sh

set -o pipefail || true
set -eu

perror () {
    1>&2 printf '%s\n' "${@:-}"
}


DEBUG="${ARCHIVE_CTL_DEBUG:-}"
AUTO_SUDO="${ARCHIVE_CTL_AUTO_SUDO:-}"

while [ $# -gt 0 ]; do
    case "${1:-}" in
        --debug|-d)
            DEBUG=1
            shift
        ;;
        --sudo)
            AUTO_SUDO=1
            shift
        ;;
        *)
            break
        ;;
    esac
done

_command="${1:-help}"
shift

hammer_cmd=hammer

if [ "x$(id -u)" != 'x0' ]; then
    if [ x$AUTO_SUDO != 'x1' ] || ! (2>/dev/null sudo -v) ; then
        perror 'error: requires superuser privileges!'
        return 140
    fi
    [ "x$DEBUG" = x1 ] && perror 'warning: not root, assuming sudo access'
    hammer_cmd='sudo -H hammer'
fi

if [ x$DEBUG = x1 ]; then
    set -x
fi

update () {
    local root="${1:-}"
    if [ x$root = x ]; then
        perror 'error: expected a mountpoint'
        return 2
    fi
    if ! mount -t hammer | greq -qE ' '$root' '; then
        perror 'error: '"$root"' is not a mounted HAMMER filesystem!'
        return 2
    fi
    if [ ! -e "$root/.archive_config" ] || [ ! -d "$root/.archive_config" ]; then
        perror 'error: missing '"$root/.archive_config"' directory!'
        return 2
    fi
}

in-pfs () {
    local target="${1:-}"
    local rc=
    local pfs_config=
    if [ "x$target" = x ]; then
        perror 'missing PATH'
        return 254
    fi
    if (>/dev/null eval $hammer_cmd pfs-status "${target}") then
        return 0
    fi
    [ x$DEBUG = x1 ] && perror 'not a pfs: '"${target}"
    return 1
}

list-mounts() {
    mount -t hammer -p | cut -f2
}

pfs-root () {
    local target="${1:-}"
    local next_target=
    if [ x"$target" = x ]; then
        perror 'error: path not given to find a root for'
        return 3
    fi
    if ! in-pfs "$target"; then
        perror 'error: not a path in a PFS!'
        return 2
    fi
    target="$(readlink -f "$target")"
    next_target="$(dirname "$target")"
    while [ x$target != x$next_target ]
    do
        case "$target" in
            */@@-1:[0-9][0-9][0-9][0-9][0-9]|*/@@0x*:[0-9][0-9][0-9][0-9][0-9])
            echo "$target"
            return 0
            ;;
            */@@-1:[0-9][0-9][0-9][0-9][0-9]/*|*/@@0x*:[0-9][0-9][0-9][0-9][0-9]/*)
            target="$next_target"
            ;;
            *)
            perror 'warn: no PFS found in path for '"$target"'!'
            break
            ;;
        esac
        next_target="$(dirname "$target")"
    done
    pfs-id "$target"
    return 1
}

pfs-id () {
    local _pad=0
    local target=
    while [ $# -gt 0 ] ; do
        case "${1:-}" in
            --pad|-p)
                _pad=1
                shift
            ;;
            -*)
                perror 'unknown argument '"${1}"'!'
                return 4
                ;;
            *)
                target="${@:-}"
                set --
            ;;
        esac
    done
    local next_target=
    if [ x"$target" = x ]; then
        perror 'error: path not given to find a root for'
        return 3
    fi
    if ! in-pfs "$target"; then
        perror 'error: not a path in a PFS!'
        return 2
    fi
    local line=
    local pfs_id=$($hammer_cmd pfs-status "$target" | head -1 | rev | cut -d# -f1 | rev | cut -f1 -d' ')
    if [ $_pad -eq 1 ]; then
        printf '%05d\n' "$pfs_id"
    else
        echo "$pfs_id"
    fi
}

PFS_ATTRIBUTES='id
type
state
snapshots
sync-beg-tid
sync-end-tid
shared-uuid
unique-uuid
label
prune-min
config
fs-uuid'

is-snapshot () {
    local target="${1:-}"
    if [ x"$target" = x ]; then
        perror 'missing target!'
        return 2
    fi
    shift
    local txn_id="${1:-}"
    if [ x"$txn_id" = x ]; then
        perror 'missing txn id!'
        return 2
    fi
    case "$txn_id" in
        */@@0x*:[0-9][0-9][0-9][0-9][0-9])
        txn_id="$(echo "$txn_id" | rev | cut -f1 -d/ | rev | cut -f1 -d:)"
        ;;
        */@@0x*)
        txn_id="$(echo "$txn_id" | rev | cut -f1 -d/ | rev)"
        ;;
        @@0x*:*)
        txn_id="$(echo "$txn_id" | cut -f1 -d:)"
        pfs_id="$(echo "$txn_id" | cut -f2 -d:)"
        ;;
        0x*)
        txn_id="$(echo "$txn_id" | cut -f1 -d:)"
        ;;
    esac
    txn_id="$(echo "$txn_id" | sed 's|@@||g')"
    eval $hammer_cmd snapls "$target" | cut -f1 | grep -qE "^$txn_id$"
}

attr-by () {
    local _print_help=0
    local target=
    local num_targets=0
    local targets=
    local next_target=
    local pfs_attrib_pattern="$(echo $PFS_ATTRIBUTES | sed 's|\n$||g' | tr ' ' '|')"

    while [ $# -gt 0 ]
    do
        case "${1:-}" in
            --help|-h|-'?')
                _print_help=1
                break
            ;;
            --)
                if [ $num_targets -gt 0 ]; then
                    shift
                    break
                fi
                perror 'no targets given!'
                _print_help=1
                break
            ;;
            -*)
                perror 'unknown option: '"${1}"' !'
                return 42
            ;;
            *)
                if echo "${1:-}" | grep -qE "$pfs_attrib_pattern"; then
                    break
                fi
                target="${1}"
                if [ ! -e "$target" -a ! -h "$target" ]; then
                    perror "$target does not exist!"
                    return 1
                fi
                shift
                if [ x"$target" = x ]; then
                    targets="${target}"
                else
                    targets="${targets}"$'\n'"${target}"
                fi
                num_targets="$(expr $num_targets \+ 1)"
            ;;
        esac
    done

    local rc=
    if [ "$num_targets" -eq 0 ]; then
        perror 'error: path not given to get attributes for'
        return 3
    fi
    if [ $num_targets -gt 1 ]; then
        IFS=$'\n'
        for target in $targets
        do
            unset IFS
            attr-by "$target" -- "${@}"
        done
        return 0
    fi
    if [ $_print_help -eq 1 ]; then
        perror "$0"' PATH ATTRIBUTE [--set VALUE | --set-from FILENAME ]
'"$0"' PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE1 ATTRIBUTE2 [...ATTRIBUTEN]
'"$0"' PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE1,ATTRIBUTE2,ATTRIBUTEN
available attributes:
    '"$(echo "$PFS_ATTRIBUTES" | xargs)"'
'
        exit 4
    fi

    if ! in-pfs "$target"; then
        perror 'error: not a path in a PFS!'
        return 2
    fi
    local attr="${1:-}"
    if [ x"$attr" = x ] || case "$attr" in -*) true ;; *) false ;; esac; then
        perror 'error: attr not given to get attributes for'
        perror 'attributes are: '"$(echo $PFS_ATTRIBUTES | xargs)"
        return 3
    fi
    shift
    local result=''
    local attr_result=
    if case "$attr" in *','*) true ;; *) false ;; esac; then
        if [ x"$@" != x ]; then
            perror 'wtf'
            return 55
        fi
        rc=0
        for attr in $(echo "$attr" | tr ',' '\n')
        do
            attr_result="$(attr-by "$target" "$attr")"
            if case "$attr_result" in *,* ) true ;; *) false ;; esac ; then
                attr_result='"'"$attr_result"'"'
            fi
            if [ x"$result" = x ]; then
                result="${attr_result}"
            else
                result="${result},${attr_result}"
            fi
        done
        echo "$result"
        return 0
    fi
    local newvalue=
    local has_set=0
    local filename=
    while [ $# -gt 0 ]
    do
        case "${1:-}" in
            --set-from)
                has_set=1
                shift
                filename="${1:-}"
                if [ x"$filename" = x ]; then
                    perror 'error: filename not given for value!'
                    return 55
                fi
                shift
                if [ x"$filename" = 'x-' ]; then
                    filename=/dev/stdin
                fi
                if [ ! -r "$filename" ]; then
                    perror 'error: '"$filename"' not readable!'
                    return 55
                fi
                IFS= read -r newvalue < "$filename"
                if [ "x$newvalue" = 'x' ]; then
                    perror 'warn: data from '"${filename}"' is empty. proceeding.'
                    exit 1
                fi
                ;;
            --set)
                has_set=1
                shift
                if [ -z "${1+x}" ]; then
                    perror 'error: missing value for --set!'
                    return 55
                fi
                if [ ! -t 0 -a x"${1}" = x- ]; then
                    IFS= read -r newvalue
                    set -- "$newvalue"
                fi
                case "$attr" in
                    label)
                    newvalue="${@}"
                    set --
                    ;;
                    *)
                    newvalue="${1}"
                    shift
                esac
            ;;
            *)
                perror 'error: unknown argument '"${1:-}"'!'
                return 5
            ;;
        esac
    done
    rc=0
    if [ $has_set -eq 1 ]; then
        case "$attr" in
            id|fs-uuid|state)
                perror 'immutable! ignoring "'"$newvalue"'" !'
                return 1
            ;;
            unique-uuid)
                perror 'why?! ignoring "'"$newvalue"'" !'
                return 1
            ;;
            sync-beg-tid|sync-end-tid)
                perror 'controlled by replication, no. ignoring "'"$newvalue"'" !'
                return 201
            ;;
            type)
            perror 'not implemented - type requires upgrade/downgrade!'
            return 201
            ;;
            config)

            ;;
            snapshots)
            perror 'not implemented'
            return 201
            if [ x$newvalue != x ]; then
                >/dev/null $hammer_cmd \
                    pfs-update "$target" \
                    snapshots-clear || rc=$?
            else
                >/dev/null $hammer_cmd \
                    pfs-update "$target" \
                    "$attr"="$newvalue" || rc=$?
            fi
            ;;
            *)
            >/dev/null $hammer_cmd \
                pfs-update "$target" \
                "$attr"="$newvalue" || rc=$?
            ;;

        esac
        if [ $rc -ne 0 ]; then
            return $rc
        fi
    fi

    case "$attr" in
        id)
            pfs-id --pad "$target"
        ;;
        fs-uuid)
            eval $hammer_cmd info "$target" | grep -E '^[[:space:]]FSID' | rev | cut -d' ' -f1 | rev
        ;;
        type|state)
        result="$(eval $hammer_cmd \
            pfs-status "$target" | \
            grep 'operating as a' | rev | cut -f1 -d' ' | rev)"
        if [ "$attr" = state ]; then
            if [ -h "$target" ]; then
            local next_target="$(readlink "$target")" || rc=$?
            while [ $rc -eq 0 ] && [ x$target != x$next_target ]; do
                if case "$next_target" in /*) false ;; *) true ;; esac ; then
                    next_target="$(dirname $target)/$next_target"
                fi
                [ x$DEBUG = x1 ] && perror "$target"'->'"$next_target"
                target="$next_target"
                rc=0
                next_target="$(readlink "$target")" || rc=$?
            done
            fi

            local context="$(basename "$target")"
            local parent="$(basename "$(dirname "$target")")"
            if [ x"$parent" != x ]; then
                context="$parent/$context"
            fi
            [ x$DEBUG = x1 ] && perror "Evaluating context=$context on target=$target"
            local pfs_subtype=
            if is-snapshot "$target" "$context" ; then
                pfs_subtype='SNAPSHOT'
            fi
            case "$context" in
                */@@-1:[0-9][0-9][0-9][0-9][0-9])

                ;;
                */@@0x*:[0-9][0-9][0-9][0-9][0-9])
                    if [ x"$pfs_subtype" = x ]; then
                        pfs_subtype=TRANSACTION
                    fi
                ;;
                */@@0x*)
                if [ x"$pfs_subtype" = x ]; then
                    pfs_subtype=TRANSACTION
                fi
                ;;
            esac
            if [ x"$pfs_subtype" != x ]; then
                result="${result}-${pfs_subtype}"
            fi
            if [ ! -e "$target" ]; then
                result="$result-INACCESSIBLE"
            fi
        fi
        echo "$result"
        ;;
        snapshots)
        eval $hammer_cmd \
            pfs-status "$target" | \
            grep 'snapshots directory' | rev | cut -f1 -d' ' | rev
        ;;
        config)
            (eval $hammer_cmd config "$target" | egrep -v '^\s*#') || true
        ;;
        *)
        eval $hammer_cmd \
            pfs-status "$target" | \
            grep "$attr"'=' | cut -f2 -d= | tr -d \"
        ;;
    esac
}

PFS_HOME='/pfs/
/.pfs/
/.archive_config/pfs/
/bind/PFS FS
'"${PFS_HOME:-}"
PFS_HOME="$(printf '%s' "$PFS_HOME" | tr '\n' ':' | sed 's|::*|:|g;s|^:||g;s|:$||g' | tr : '\n')"

find-mount-for-pfs () {
    local target="${1:-}"
    if [ x"$target" = x ]; then
        perror 'error: no PATH given.'
        return 1
    fi
    local line=
    local mount_uuid=
    local target_fs_uuid=
    if ! in-pfs "$target"; then
        perror 'error: not in a PFS, specify a path to one!'
        return 1
    fi
    target_fs_uuid=$(attr-by "$target" -- fs-uuid)
    if ! list-mounts | while IFS=$'\n' read line
    do
        mount_uuid=$(attr-by "$line" -- fs-uuid)
        if [ x$mount_uuid = x$target_fs_uuid ]; then
            echo "$line"
            break
        fi
    done; then
        perror 'error: Unable to find a match for mounted HAMMER with fs-uuid: '"${target_fs_uuid}"'.'
        return 1
    fi
}

pfs-home () {
    local target="${1:-}"
    local mount_point=
    local line=
    local path=
    local matchedfile=
    local rc=0
    local pfs_id=
    local pfs_type=
    local txn_id='-1'
    if [ x"$target" = x ]; then
        perror 'error: no PATH given.'
        return 1
    fi
    mount_point="$(find-mount-for-pfs "${target}")"
    pfs_id="$(pfs-id --pad "$target")"
    pfs_type=$(attr-by "$target" type )
    if [ x"$mount_point" = x ]; then
        perror 'fatal: unable to find mount point for '"${target}"
        return 2
    fi

    local OIFS=
    local maybe_pfs_home=
    IFS=$'\n'
    for line in ${PFS_HOME}
    do
        IFS="$OIFS"
        line="$(printf "%s\n" "$line" | sed 's|^/||g')"
        maybe_pfs_home="$mount_point/$line"
        if ! [ -d "$maybe_pfs_home" ]; then
            continue
        fi
        rc=0
        line=
        if [ "$pfs_type" = 'MASTER' ]; then
            matchedfile="$(find "$(realpath "$maybe_pfs_home")" -lname '@@-1:'"$pfs_id"'*' -print -quit)" || line=
        else
            matchedfile="$(find "$(realpath "$maybe_pfs_home")" -lname '@@'"$(attr-by "$target" sync-end-tid)"':'"$pfs_id"'*' -print -quit)" || line=
        fi
        if [ x"$matchedfile" != x ]; then
            echo "$matchedfile"
            return 0
        fi
    done
    if [ "$pfs_type" = MASTER ]; then
        perror 'warn: unable to find a friendly link to PFS#'"${pfs_id}"
        echo "${mount_point}/@@-1:${pfs_id}"
    fi
}


list-pfs () {
    local line=
    local _show_root=0
    local target=
    local found=0
    local rc=
    local pfs_id=
    local seen_pfs=''

    while [ $# -gt 0 ]
    do
        case "${1:-}" in
            --all|-a)
                _show_root=1
                shift
                ;;
            -*)
                perror 'error: unknown argument '"${1:-}"'!'
                return 5
            ;;
            *)
                if [ x"${1:-}" = x ]; then
                    perror 'no mounted hammer filesystems given!'
                    return 4
                fi
                break
            ;;
        esac
    done
    local extra=
    if [ $# -gt 1 ]; then
        if [ $_show_root -eq 1 ]; then
            extra='--all'
        fi
        while [ $# -gt 0 ]; do
            rc=0
            list-pfs $extra "${1}" || rc=$?
            shift
            if [ $rc -ne 0 ]; then
                return $rc
            fi
        done
        return 0
    fi
    target="${1:-}"
    if [ x"$target" = x ]; then
        perror 'error: no target given!'
        return 2
    fi
    for maybe_mnt_pt in $(list-mounts)
    do
        case "$(readlink -f "$target")" in
            "$maybe_mnt_pt"/*|"$maybe_mnt_pt")
                mnt_pt="$maybe_mnt_pt"
                found=1
                break
            ;;
        esac
    done
    if [ $found -eq 0 ]; then
        perror 'not the direct mount!'
        return 2
    fi
    local pfs_id=
    local latest_txn=
    $hammer_cmd info $1 | while read line
    do
        case "$line" in
            *PFS#*Mode*Snaps*)
                found=1
                continue
                ;;
        esac
        if [ $found -eq 1 ]; then
            pfs_id=
            if case "$line" in *'(root PFS)'*) true ;; *) false ;; esac && [ "$_show_root" -eq 0 ]; then
                continue
            fi
            case "$line" in
                [0-9]*MASTER*)
                    pfs_id="$(echo $line | cut -f1 -d' ')"
                    printf "$mnt_pt/@@-1:%05d\n" $pfs_id
                    ;;
                [0-9]*SLAVE*)
                    pfs_id="$(echo $line | cut -f1 -d' ')"
                    latest_txn="$(hammer pfs-status $(printf "$mnt_pt/@@-1:%05d\n" $pfs_id) | grep 'sync-end-tid=' | cut -f2- -d=)"
                    printf "$mnt_pt/@@%s:%05d\n" $latest_txn $pfs_id
                    ;;
            esac
        fi
    done
}



typeof_pfs () {
    local target="${1:-}"
    local rc=0
    local pfs_type=
    if [ "x$target" = x ]; then
        perror 'missing PFS for $1!'
        return 254
    fi
    in-pfs "$target" || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    case "$($hammer_cmd pfs-status "$target")" in
        *'operating as a SLAVE'*)
            pfs_type=REPLICA
        ;;
        *'operating as a MASTER'*)
            # might either be a primary or a snapshot
            # on a primary
            pfs_type=PRIMARY
        ;;
        *)
            perror 'error: unknown PFS type!'
            pfs_type=UNKNOWN
        ;;
    esac
    rc=0
    local next_target="$(readlink "$target")" || rc=$?
    while [ $rc -eq 0 ] && [ x$target != x$next_target ]; do
        if case "$next_target" in /*) false ;; *) true ;; esac ; then
            next_target="$(dirname $target)/$next_target"
        fi
        [ x$DEBUG = x1 ] && perror "$target"'->'"$next_target"
        target="$next_target"
        rc=0
        next_target="$(readlink "$target")" || rc=$?
    done
    local context="$(basename "$target")"
    local parent="$(basename "$(dirname "$target")")"
    if [ x"$parent" != x ]; then
        context="$parent/$context"
    fi
    [ x$DEBUG = x1 ] && perror "Evaluating context=$context on target=$target"
    case "$context" in
        */@@-1:[0-9][0-9][0-9][0-9][0-9])

        ;;
        */@@0x*:[0-9][0-9][0-9][0-9][0-9])
            pfs_type="${pfs_type}-TRANSACTION"
        ;;
        */@@0x*)
            pfs_type="${pfs_type}-SNAPSHOT"
        ;;
    esac
    if [ ! -e "$target" ]; then
        pfs_type="$pfs_type-INACCESSIBLE"
    fi
    echo $pfs_type
}

list_replicas_for_pfs () {
    local pfs=${}
}

help () {
    perror "$0"' [ACTION] [...]
        upgrade - upgrades an archive to be a primary
        downgrade
        in-pfs - return 0 if is a PFS or within a PFS

'
}

rc=$?
"${_command}" "$@" || rc=$?
exit $rc
