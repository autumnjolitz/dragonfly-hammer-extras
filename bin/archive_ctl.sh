#!/usr/bin/env sh

set -o pipefail || true
set -eu

DEBUG="${ARCHIVE_CTL_DEBUG:-}"

# shellcheck source-path=SCRIPTDIR
ARCHIVE_CTL_LIB="${ARCHIVE_CTL_LIB:-"$(dirname "$( realpath "$0")")"}"
[ '1' = "${DEBUG:-}" ] && >&2 echo ARCHIVE_CTL_LIB="${ARCHIVE_CTL_LIB}"

default_commands_delim=-

# shellcheck source=bin/common.sh
. "${ARCHIVE_CTL_LIB}/common.sh"

archive_ctl_commands=''

AUTO_SUDO="${ARCHIVE_CTL_AUTO_SUDO:-}"

if assert_var 'ARCHIVE_CTL_EXPORT_DEBUG_INTERNALS'; then
    archive_ctl_export_internals="${ARCHIVE_CTL_EXPORT_DEBUG_INTERNALS}"
fi

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
        --export-debug-internals)
            archive_ctl_export_internals=1
            shift
        ;;
        *)
            break
        ;;
    esac
done
case "${1:-help}" in
    -h|--help|help)
        if [ $# -gt 0 ]; then
            shift
        fi
        set -- help "$@"
    ;;
esac

hammer_cmd="${ARCHIVE_CTL_HAMMER_COMMAND:-hammer}"

if [ "$(id -u)" != '0' ]; then
    if [ "$AUTO_SUDO" = '0' ] || ([ "$AUTO_SUDO" = '1' ] && ! 2>/dev/null sudo -v) ; then
        perror 'error: requires superuser privileges!'
        exit 140
    fi
    [ "$DEBUG" = '1' ] && perror 'warning: not root, assuming sudo access'
    hammer_cmd="sudo -H $hammer_cmd"
fi

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
fs-uuid
home'

pfs_home_search_paths='/pfs/
/.pfs/
/.archive_config/pfs/
'"${ARCHIVE_CTL_PFS_SEARCH_PATHS:-}"

pfs_home_search_paths="$(printf '%s' "$pfs_home_search_paths" | tr '\n' ':' | sed 's|::*|:|g;s|^:||g;s|:$||g' | tr : '\n')"

if [ "$DEBUG" = '1' ]; then
    set -x
fi

# shellcheck disable=SC2329
update () {
    local root="${1:-}"
    if [ "$root" = '' ]; then
        perror 'error: expected a mountpoint'
        return 2
    fi
    if ! mount -t hammer | greq -qE ' '"$root"' '; then
        perror 'error: '"$root"' is not a mounted HAMMER filesystem!'
        return 2
    fi
    if [ ! -e "$root/.archive_config" ] || [ ! -d "$root/.archive_config" ]; then
        perror 'error: missing '"$root/.archive_config"' directory!'
        return 2
    fi
}

# shellcheck disable=SC2329
in_pfs () {
    local target="${1:-}"
    local rc=0
    if [ "$target" = '' ]; then
        perror 'missing PATH'
        return 254
    fi
    >/dev/null eval "$hammer_cmd" pfs-status "${target}" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    return "$rc"
}

# shellcheck disable=SC2329
list_mounts() {
    mount -t hammer -p | cut -f2
}

# shellcheck disable=SC2329
pfs_id () {
    local _pad=0
    local rc=0
    local target=
    local maybe_delim=
    local delim=
    local default_delim=','
    local escaped_default_delim=
    local OIFS=
    local pfs=

    escaped_default_delim="$(printf '%s' "$default_delim")"

    while [ $# -gt 0 ] ; do
        case "${1:-}" in
            --pad|-p)
                _pad=1
                shift
            ;;
            --help|-h)
                perror 'pfs-id [-p | --pad] PATH [PATH] [... [PATH]]

General flags:
    -D --delim'"${TAB}"' character to use as a delimiter (defaults to '"'${escaped_default_delim}'"')
    -p --pad'"${TAB}"' pad out the id to match '"'"'%05d'"'"'

Returns the pfs id of PATH
'
                return 2
                ;;
            -D|--delim)
                shift
                maybe_delim="${1:-}"
                if [ "$maybe_delim" = '' ]; then
                    perror 'missing delimiter value!'
                    return 2
                fi
                shift
                case "${maybe_delim}" in
                    \\*)
                        maybe_delim="$(printf '%b' "${maybe_delim}")"
                    ;;
                esac
                delim="${maybe_delim}"
                if [ "$(printf '%s' "$delim" | wc -c)" -gt 1 ]; then
                    perror 'delimiter may not exceed one character!'
                    return 2
                fi
            ;;

            -*)
                perror 'unknown argument '"${1}"'!'
                return 4
                ;;
            *)
                if ! in_pfs "${1}"; then
                    perror 'error: '"${1} is not a pfs!"
                    return 1
                fi
                if [ "$target" = '' ]; then
                    target="$1"
                else
                    target="${target}${NEWLINE}${1}"
                fi
                shift
            ;;
        esac
    done
    OIFS="${IFS}"
    IFS="${NEWLINE}"
    for pfs in $target
    do
        set -- "$@" "$pfs"
    done
    IFS="$OIFS"

    if [ $# -eq 0 ]; then
        perror 'error: path not given to find a root for'
        return 3
    fi
    local pfs_id=
    $hammer_cmd pfs-status "$@" | grep -e 'PFS#' -e '[[:digit:]]* {$' | rev | cut -d# -f1 | rev | cut -f1 -d' ' | while IFS="${NEWLINE}" read -r pfs_id; do
        if [ "${_pad}" -eq 1 ]; then
            printf '%05d\n' "$pfs_id"
        else
            printf '%d\n' "$pfs_id"
        fi
    done | tr '\n' "$delim"
}

# shellcheck disable=SC2329
is_snapshot () {
    local target="${1:-}"
    local rc=0
    local txn_id=
    local next_target=
    if [ "$target" = '' ]; then
        perror 'missing target!'
        return 2
    fi
    shift
    local txn_id="${1:-}"
    shift
    if [ -h "$target" ]; then
        rc=0
        next_target="$(readlink "$target")" || rc=$?
        while [ "$rc" -eq 0 ] && [ "$target" != "$next_target" ]; do
            if case "$next_target" in /*) false ;; *) true ;; esac ; then
                next_target="$(dirname "$target")/$next_target"
            fi
            [ "$DEBUG" = '1' ] && perror "$target"'->'"$next_target"
            target="$next_target"
            rc=0
            next_target="$(readlink "$target")" || rc=$?
        done
    fi

    case "$target" in
        */@@0x*)
            if [ "$txn_id" = '' ]; then
                txn_id="$(echo "$target" | rev | cut -f1 -d/ | rev)"
            fi
        ;;
    esac
    target="$(pfs_home "$target")"
    if case "$txn_id" in @@*:*) true ;; *) false ;; esac; then
        txn_id="$(echo "$txn_id" | cut -f1 -d:)"
    fi
    if [ "$txn_id" = '' ]; then
        perror 'missing txn id!'
        return 2
    fi
    txn_id="$(printf '%s' "${txn_id}" | sed 's|@@||g')"
    eval "$hammer_cmd" snapls "$target" | cut -f1 | grep -qE "^$txn_id$"
}

# shellcheck disable=SC2329
by_attr () {
    local _print_help=0
    local target=
    local num_targets=0
    local targets=
    local exe=
    local next_target=
    local context=
    local pfs_attrib_pattern=
    local attr=
    local maybe_attr=
    local _has_bad_attr=0
    local delim=
    local default_delim=','
    local maybe_delim=
    local _break_at_first_attribute=1

    if case "$*" in *' -- '*) true ;; *) false ;; esac; then
        _break_at_first_attribute=0
    fi

    pfs_attrib_pattern="$(printf '%s\n' "$PFS_ATTRIBUTES" | trim | join_by_delimiter ':')"
    while [ $# -gt 0 ]
    do
        case "${1:-}" in
            --help|-h|-'?')
                _print_help=1
                break
            ;;
            -D|--delim)
                shift
                maybe_delim="${1:-}"
                if [ "$maybe_delim" = '' ]; then
                    perror 'missing delimiter value!'
                    return 2
                fi
                shift
                case "${maybe_delim}" in
                    \\*)
                        maybe_delim="$(printf '%b' "${maybe_delim}")"
                    ;;
                esac
                delim="${maybe_delim}"
                if [ "$(printf '%s' "$delim" | wc -c)" -gt 1 ]; then
                    perror 'delimiter may not exceed one character!'
                    return 2
                fi
            ;;
            --)
                if [ "$num_targets" -gt 0 ]; then
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
                if [ "$_break_at_first_attribute" -eq 1 ] && case :"${pfs_attrib_pattern}": in *":$(echo "${1}" | tr "${delim:-$default_delim}" ':'):"*) true ;; *) false ;; esac ; then
                    # ambiguous case, use -- to seperate
                    # paths from attributes!
                    # if [ "$num_targets" -gt 1 ]; then
                    #     perror 'warning: assuming "'"$(echo "${1}" | tr "$delim" ' ')"'" are attributes.'
                    # fi
                    break
                fi
                target="${1}"
                if [ ! -e "$target" ] && [ ! -h "$target" ]; then
                    perror 'warning: '"${target}"' does not exist!'
                    # return 1
                fi
                shift
                if [ "$target" = '' ]; then
                    targets="${target}"
                else
                    targets="${targets}${NEWLINE}${target}"
                fi
                num_targets="$(( num_targets + 1 ))"
            ;;
        esac
    done
    if [ "$num_targets" -eq 0 ] && [ "$_print_help" -ne 1 ]; then
        perror 'error: path not given to get attributes for'
        _print_help=1
    fi
    escaped_default_delim="$(printf '%s' "$default_delim")"
    exe="$(basename "$0")"
    if [ "$_print_help" -eq 1 ]; then
        perror "$exe"' PATH ATTRIBUTE [--set VALUE | --set-from FILENAME ]
'"$exe"' PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE
'"$exe"' PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE1,ATTRIBUTE2,ATTRIBUTEN

General flags:

-D --delim'"${TAB}"' character to use as a delimiter (defaults to '"'${escaped_default_delim}'"')

available attributes:
    '"$(echo "$PFS_ATTRIBUTES" | join_by_delimiter ', ' )"'
'
        return 4
    fi
    delim="${delim:-$default_delim}"

    while [ $# -gt 0 ]; do
        case "${1}" in
            --*)
                break
                ;;
            *)
                maybe_attr="${1}"
                shift
                if [ "$attr" = '' ]; then
                    attr="$maybe_attr"
                else
                    attr="${attr}${delim}${maybe_attr}"
                fi
            ;;
        esac
    done

    if [ "${attr}" = '' ] ; then
        perror 'error: attr not given to get attributes for'
        perror 'attributes are: '"$(echo "$PFS_ATTRIBUTES" | join_by_delimiter ', ')"
        return 3
    fi
    # if case "$attr" in *"${delim}"*) true ;; *) false ;; esac; then

    # fi
    for maybe_attr in $(echo "${attr}" | tr "${delim}" '\n')
    do
        if ! case :"${pfs_attrib_pattern}": in *":$(printf '%s' "${maybe_attr}" | tr "$delim" ':'):"*) true ;; *) false ;; esac ; then
            perror "${maybe_attr}"' is not a valid attribute!'
            _has_bad_attr=1
        fi
    done
    if [ "${_has_bad_attr}" -eq 1 ]; then
        return 3
    fi


    local rc=
    if [ "$num_targets" -gt 1 ]; then
        IFS="${NEWLINE}"
        for target in $targets
        do
            unset IFS
            by_attr "$target" -- "${@}"
        done
        return 0
    fi

    if ! in_pfs "$target"; then
        perror 'error: '"$target"' is not a path in a PFS!'
        return 2
    fi
    local result=''
    local attr_result=
    local next_target=
    local newvalue=
    local has_set=0
    local filename=
    local parent=

    if case "$attr" in *"${delim}"*) true ;; *) false ;; esac; then
        if [ $# -ne 0 ]; then
            perror 'wtf'
            return 55
        fi
        rc=0
        for attr in $(echo "$attr" | tr "${delim}" '\n')
        do
            attr_result="$(by_attr "$target" "$attr")"
            if case "$attr_result" in *"${delim}"* ) true ;; *) false ;; esac ; then
                attr_result='"'"$attr_result"'"'
            fi
            if [ "$result" = '' ]; then
                result="${attr_result}"
            else
                result="${result}${delim}${attr_result}"
            fi
        done
        echo "$result"
        return 0
    fi
    while [ $# -gt 0 ]
    do
        case "${1:-}" in
            --set-from)
                has_set=1
                shift
                filename="${1:-}"
                if [ "$filename" = '' ]; then
                    perror 'error: filename not given for value!'
                    return 55
                fi
                shift
                if [ "$filename" = '-' ]; then
                    filename=/dev/stdin
                fi
                if [ ! -r "$filename" ]; then
                    perror 'error: '"$filename"' not readable!'
                    return 55
                fi
                IFS= read -r newvalue < "$filename"
                if [ "$newvalue" = '' ]; then
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
                if [ ! -t 0 ] && [ "${1}" = '-' ]; then
                    IFS= read -r newvalue
                    set -- "$newvalue"
                fi
                case "$attr" in
                    label)
                    newvalue="$*"
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
    if [ "$has_set" -eq 1 ]; then
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
            printf '%s\n' "$newvalue" | eval "$hammer_cmd" pfs config /dev/stdin || rc=$?
            ;;
            home)
            perror 'not implemented'
            return 201
            ;;
            snapshots)
            perror 'not implemented'
            return 201
            # if [ "$newvalue" = '' ]; then
            #     >/dev/null $hammer_cmd \
            #         pfs-update "$target" \
            #         snapshots-clear || rc=$?
            # else
            #     >/dev/null $hammer_cmd \
            #         pfs-update "$target" \
            #         "$attr"="$newvalue" || rc=$?
            # fi
            ;;
            *)
            >/dev/null $hammer_cmd \
                pfs-update "$target" \
                "$attr"="$newvalue" || rc=$?
            ;;

        esac
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
    fi

    case "$attr" in
        id)
            run pfs-id --pad "$target"
        ;;
        home)
            run pfs-home "$target"
        ;;
        fs-uuid)
            eval "$hammer_cmd" info "$target" | grep -E '^[[:space:]]FSID' | rev | cut -d' ' -f1 | rev
        ;;
        type|state)
        result="$(eval "$hammer_cmd" pfs-status "$target" | grep 'operating as a' | rev | cut -f1 -d' ' | rev)"
        if [ "$attr" = state ]; then
            if [ -h "$target" ]; then
            next_target="$(readlink "$target")" || rc=$?
            while [ "$rc" -eq 0 ] && [ "$target" != "$next_target" ]; do
                if case "$next_target" in /*) false ;; *) true ;; esac ; then
                    next_target="$(dirname "$target")/$next_target"
                fi
                [ "$DEBUG" = '1' ] && perror "$target"'->'"$next_target"
                target="$next_target"
                rc=0
                next_target="$(readlink "$target")" || rc=$?
            done
            fi

            context="$(basename "$target")"
            parent="$(basename "$(dirname "$target")")"
            if [ "$parent" != '' ]; then
                context="$parent/$context"
            fi
            [ "$DEBUG" = '1' ] && perror "Evaluating context=$context on target=$target"
            local pfs_subtype=
            if is_snapshot "$target" "$context" ; then
                pfs_subtype='SNAPSHOT'
            fi
            case "$context" in
                */@@-1:[0-9][0-9][0-9][0-9][0-9])

                ;;
                */@@0x*:[0-9][0-9][0-9][0-9][0-9])
                    if [ "$pfs_subtype" = '' ]; then
                        pfs_subtype=TRANSACTION
                    fi
                ;;
                */@@0x*)
                if [ "$pfs_subtype" = '' ]; then
                    pfs_subtype=TRANSACTION
                fi
                ;;
            esac
            if [ "$pfs_subtype" != '' ]; then
                result="${result}-${pfs_subtype}"
            fi
            if [ ! -e "$target" ]; then
                result="$result-INACCESSIBLE"
            fi
        fi
        echo "$result"
        ;;
        snapshots)
        eval "$hammer_cmd" \
            pfs-status "$target" | \
            grep 'snapshots directory' | rev | cut -f1 -d' ' | rev
        ;;
        config)
            (eval "$hammer_cmd" config "$target" | grep -vE '^\s*#') || true
        ;;
        *)
        eval "$hammer_cmd" \
            pfs-status "$target" | \
            grep "$attr"'=' | cut -f2 -d= | tr -d \"
        ;;
    esac
}

# shellcheck disable=SC2329
find_mount_for_pfs () {
    local target="${1:-}"
    if [ "$target" = '' ]; then
        perror 'error: no PATH given.'
        return 1
    fi
    local line=
    local mount_uuid=
    local target_fs_uuid=
    if ! in_pfs "$target"; then
        perror 'error: not in a PFS, specify a path to one!'
        return 1
    fi
    target_fs_uuid=$(by_attr "$target" -- fs-uuid)
    if ! list_mounts | while IFS="${NEWLINE}" read -r line
    do
        mount_uuid=$(by_attr "$line" -- fs-uuid)
        if [ "$mount_uuid" = "$target_fs_uuid" ]; then
            echo "$line"
            break
        fi
    done; then
        perror 'error: Unable to find a match for mounted HAMMER with fs-uuid: '"${target_fs_uuid}"'.'
        return 1
    fi
}

# shellcheck disable=SC2329
pfs_home () {
    local target="${1:-}"
    local mount_point=
    local maybe_home=
    local matchedfile=
    local rc=0
    local pfs_id=
    local pfs_type=
    local txn_id='-1'
    local OIFS=
    local maybe_pfs_home=

    if [ "$target" = '' ]; then
        perror 'error: no PATH given.'
        return 1
    fi
    mount_point="$(find_mount_for_pfs "${target}")"
    pfs_id="$(pfs_id --pad "$target")"
    pfs_type=$(by_attr "$target" type )
    if [ "$mount_point" = '' ]; then
        perror 'fatal: unable to find mount point for '"${target}"
        return 2
    fi

    IFS="${NEWLINE}"
    for maybe_home in ${pfs_home_search_paths}
    do
        IFS="$OIFS"
        maybe_home="$(printf "%s\n" "$maybe_home" | sed 's|^/||g')"
        maybe_pfs_home="$mount_point/$maybe_home"
        if ! [ -d "$maybe_pfs_home" ]; then
            continue
        fi
        rc=0
        if [ "$pfs_type" = 'MASTER' ]; then
            matchedfile="$(find "$(realpath "$maybe_pfs_home")" -lname '@@-1:'"$pfs_id"'*' -print -quit)" || line=
        else
            matchedfile="$(find "$(realpath "$maybe_pfs_home")" -lname '@@'"$(by_attr "$target" sync-end-tid)"':'"$pfs_id"'*' -print -quit)" || line=
        fi
        if [ "$matchedfile" != '' ]; then
            echo "$matchedfile"
            return 0
        fi
    done
    if [ "$pfs_type" = MASTER ]; then
        perror 'warn: unable to find a friendly link to PFS#'"${pfs_id}"
        echo "${mount_point}/@@-1:${pfs_id}"
    fi
}

# shellcheck disable=SC2329
pfs_list () {
    local line=
    local _show_root=0
    local target=
    local found=0
    local rc=
    local pfs_id=

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
                if [ "${1:-}" = '' ]; then
                    perror 'no mounted hammer filesystems given!'
                    return 4
                fi
                break
            ;;
        esac
    done
    local extra=
    if [ $# -gt 1 ]; then
        if [ "$_show_root" -eq 1 ]; then
            extra='--all'
        fi
        while [ $# -gt 0 ]; do
            rc=0
            eval pfs_list "$extra" "${1}" || rc=$?
            shift
            if [ "$rc" -ne 0 ]; then
                return "$rc"
            fi
        done
        return 0
    fi
    target="${1:-}"
    if [ "$target" = '' ]; then
        perror 'error: no target given!'
        return 2
    fi
    for maybe_mnt_pt in $(list_mounts)
    do
        case "$(readlink -f "$target")" in
            "$maybe_mnt_pt"/*|"$maybe_mnt_pt")
                mnt_pt="$maybe_mnt_pt"
                found=1
                break
            ;;
        esac
    done
    if [ "$found" -eq 0 ]; then
        perror 'not the direct mount!'
        return 2
    fi
    local pfs_id=
    local latest_txn=
    $hammer_cmd info "$1" | while read -r line
    do
        case "$line" in
            *PFS#*Mode*Snaps*)
                found=1
                continue
                ;;
        esac
        if [ "$found" -eq 1 ]; then
            pfs_id=
            if case "$line" in *'(root PFS)'*) true ;; *) false ;; esac && [ "$_show_root" -eq 0 ]; then
                continue
            fi
            case "$line" in
                [0-9]*MASTER*)
                    pfs_id="$(echo "$line" | cut -f1 -d' ')"
                    printf "$mnt_pt/@@-1:%05d\n" "$pfs_id"
                    ;;
                [0-9]*SLAVE*)
                    pfs_id="$(echo "$line" | cut -f1 -d' ')"
                    latest_txn="$(hammer pfs-status "$(printf "$mnt_pt/@@-1:%05d\n" "$pfs_id")" | grep 'sync-end-tid=' | cut -f2- -d=)"
                    printf "$mnt_pt/@@%s:%05d\n" "$latest_txn" "$pfs_id"
                    ;;
            esac
        fi
    done
}

# shellcheck disable=SC2329
list_replicas_for_pfs () {
    local _print_help=0
    local pfs=
    local OIFS=

    while [ $# -gt 0 ]; do
        case "${1}" in
            --help|-h)
                _print_help=1
                break
                ;;
            -*)
                perror 'unknown option: '"'${1}'"
                return 2
                ;;
            *)
                if [ "$pfs" = '' ]; then
                    pfs="${1}"
                else
                    pfs="${pfs}${NEWLINE}${1}"
                fi
                shift
                ;;
        esac
    done
    if [ "$_print_help" -eq 1 ]; then
        perror "$0"' list_replicas_for_pfs PFS [PFS] ... [PFS]
'
        return 2
    fi
    pfs="$(printf '%s\n' "$pfs" | trim)"
    OIFS="${IFS}"
    IFS="${NEWLINE}"
    for pfs in $pfs
    do
        set -- "$@" "$pfs"
    done
    IFS="$OIFS"
    if [ $# -eq 0 ]; then
        perror 'no path to PFS given!'
        return 2
    fi
    local pfs_ids="$(run pfs-id "$@")"
    echo "$pfs_ids"
}

# shellcheck disable=SC2329
help () {
    # ARJ: false positive on --export-debug-internals'"${TAB}"'
    # shellcheck disable=SC2016
    perror "$0"' [-d | --debug] [--sudo] [ACTION] [...]

A more fluent interface for managing HAMMER (and hopefully later HAMMER2)
mirroring and configuration.

General flags:
    --sudo'"${TAB}"' use "sudo -H" when not superuser.

Debugging flags:
    -d --debug'"${TAB}"' "set -x" in shell for debugging output.
    --export-debug-internals'"${TAB}"' allow calling non-exported functions.

Environment variables:
    ARCHIVE_CTL_AUTO_SUDO
    ARCHIVE_CTL_DEBUG
    ARCHIVE_CTL_EXPORT_DEBUG_INTERNALS
    ARCHIVE_CTL_PFS_SEARCH_PATHS - additional colon delimited paths
                      to search for canonical PFS symbolic links. Defaults to empty.
    ARCHIVE_CTL_LIB - search path for common.sh et al.
                      Defaults to "$(realpath "'"$0"'")"

Canonical PFS search paths are:'"${NEWLINE}${TAB}'$(printf '%s' "$pfs_home_search_paths" | tr '\n' ':')'"'

Available actions: '"${NEWLINE}  $(list_registered_commands archive_ctl | join_by_delimiter '\n  ')"'
'
}

run () {
    local rc=0
    local _command="${1:-}"
    shift
    _command="$(printf '%s\n' "$_command" | sed 's|-|_|g')"
    case ":${archive_ctl_commands}:" in
        *":${_command}:"*)
            ;;
        *)
            if ! [ "${archive_ctl_export_internals:-0}" -eq 1 ]; then
                perror 'action: '"'$_command'"' not recognized!'"${NEWLINE}"
                _command=help
            fi
            ;;
    esac
    "$_command" "$@" || rc=$?
    return "$rc"
}

# register_command archive_ctl update
# register_command archive_ctl list_replicas_for_pfs
# register_command archive_ctl mirror
register_command archive_ctl help
register_command archive_ctl by_attr
register_command archive_ctl find_mount_for_pfs
register_command archive_ctl in_pfs
register_command archive_ctl is_snapshot
register_command archive_ctl list_mounts
register_command archive_ctl pfs_home
register_command archive_ctl pfs_id
register_command archive_ctl pfs_list

run "$@"
