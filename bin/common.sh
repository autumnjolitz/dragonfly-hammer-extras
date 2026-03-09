# source into a a script

here () {
    dirname "$( realpath "$0")"
}

perror () {
    1>&2 printf '%s\n' "${@:-}"
}

assert_var() {
    local rc=0
    eval '[ -z ${'"$1"'+x} ] && rc=1'
    return "$rc"
}

register_command () {
    local namespace="${1:-}"
    shift
    local target="${1:-}"
    shift
    local varname="${namespace}_commands"
    local newvalue=
    local rc=
    if [ "$namespace" = '' ] || [ "$target" = '' ]; then
        perror 'register_command namespace command
'
        return 44
    fi
    if ! assert_var "$varname" ; then
        perror "error: assert: define ${namespace}_commands"' first!'
        return 2
    fi
    if ! case "$(type "$target" | head -1)" in "${target}"*is*a*shell*function|"$target"*is*a*function) true ;; *) false ;; esac ; then
        perror 'function not defined: '"${target}: type is: $(type "$target" | head -1)"
        return 2
    fi
    rc=0
    newvalue="$(dgetenv "$varname")" || rc=$?
    if [ "$newvalue" = '' ]; then
        newvalue="${target}"
    else
        newvalue="${newvalue}:${target}"
    fi
    eval "${varname}='${newvalue}'"
    if [ "$(dgetenv "${varname}")" != "${newvalue}" ]; then
        perror 'error: assert: did not set '"$varname"'!'
        return 2
    fi
}

default_commands_delim="${default_commands_delim:-_}"

list_registered_commands() {
    local delim="${default_commands_delim:-_}"
    local namespace=

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
            perror 'list_registered_commands NAMESPACE [-d DELIM]

DELIM defaults to _
'
            return 44
            ;;
            -d|--delimiter)
                shift
                if [ "$1" = '' ]; then
                    perror 'delimiter missing!'
                    return 1
                fi
                delim="${1}"
                shift
            ;;
            -*)
                perror 'unknown option: '"$1"
                return 3
            ;;
            *)
                namespace="$1"
                shift
                break
        esac
    done
    if [ "${namespace}" = '' ]; then
        perror 'error: namespace undefined to list commands on!'
        return 1
    fi
    local varname="${namespace}_commands"
    if ! assert_var "$varname" ; then
        perror 'missing: '"${varname}"'=!'
        return 2
    fi
    dgetenv "${varname}" | tr ':' '\n' | sed 's|-|'"${delim}"'|g;s|_|'"${delim}"'|g'
}

dgetenv () {
    local varname="${1:-}"
    shift
    if [ "$varname" = '' ]; then
        perror 'missing varname'
        return 2
    fi
    if ! assert_var "$varname"; then
        return 1
    fi
    eval 'printf %s $'"$varname"
}

trim () {
    local _skip_empty=1
    local line=
    while [ $# -gt 0 ]; do
        case "${1:-}" in
            -e|--skip-empty)
                _skip_empty=1
                shift
            ;;
            -E|--keep-empty)
                _skip_empty=0
                shift
            ;;
            -h|-'?'|--help)
                perror 'trim -eE
trim [--skip-empty | --keep-empty ] '"'"' some  string  '"'"'

can also accept stdin so you can pipe to it.
'
                return 1
            ;;
            *)
                break
            ;;
        esac
    done
    if [ ! -t 0 ]; then
        while IFS="${NEWLINE}" read -r line
        do
            line="$(printf '%s\n' "$line" | sed 's|^ *||g;s| *$||g')"
            if [ $_skip_empty -eq 1 ] && [ "$line" = '' ]; then
                continue
            fi
            echo "$line"

        done < /dev/stdin
        return 0
    else
        local extra=
        if [ $_skip_empty -eq 1 ]; then
            extra=-e
        elif [ $_skip_empty -eq 0 ]; then
            extra=-E
        fi
        printf '%s\n' "${@}" | trim "$extra"
    fi
}

py () {
    local s="${1:-}"
    shift
    python3 -S -c '
from pathlib import Path
import sys, os
i = sys.argv.index("--")
sys.argv = sys.argv[i+1: ]

'"${s}" -- "${@}"
}

NEWLINE='
'
TAB="$(printf '\t')"
export NEWLINE TAB

join_by_delimiter () {
    local line=
    local result=
    local _skip_empty=1
    local delim=','
    while [ $# -gt 0 ]; do
        case "${1:-}" in
            --keep-empty|-e)
                _skip_empty=0
                shift
            ;;
            --skip-empty|-E)
                _skip_empty=1
                shift
            ;;
            -h|-'?'|--help)
                perror 'join_by_delimiter -Ee [DELIM] [VAL1] [VAL2] ...
join_by_delimiter [--skip-empty | --keep-empty ] [DELIM] [VAL1] [VAL2] ...

can also accept stdin so you can pipe to it:

echo $'"'"'foo\n\nbar\n'"'"' | '"$0"' join_by_delimiter -E '"'\n'"'

'
                return 1
            ;;
            -*)
                perror 'unknown option: '"${1:-}"
                return 4
            ;;
            *)
                delim="${1}"
                shift
                break
            ;;
        esac
    done
    local pattern='%s'"${delim}"'%s\n'
    if [ ! -t 0 ]; then
        while IFS="${NEWLINE}" read -r line
        do
            if [ $_skip_empty -eq 1 ] && [ "${line}" = '' ]; then
                continue
            fi
            if [ "$result" = '' ]; then
                result="$line"
            else
                # shellcheck disable=2059
                result="$(printf "$pattern" "${result}" "${line}")"
            fi
        done < /dev/stdin
        printf '%s\n' "$result"
        return 0
    fi
    while [ $# -gt 0 ]; do
        line="$1"
        shift
        if [ $_skip_empty -eq 1 ] && [ "${line}" = '' ]; then
            continue
        fi
        if [ "$result" = '' ]; then
            result="$line"
        else
            # shellcheck disable=SC2059
            result="$(printf "$pattern" "${result}" "${line}")"
        fi
    done
    printf '%s\n' "$result"
}
