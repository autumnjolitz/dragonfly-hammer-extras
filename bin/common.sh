# source into a a script

here () {
    echo "$(dirname "$( realpath "$0")")"
}

perror () {
    1>&2 printf '%s\n' "${@:-}"
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
        while IFS=$'\n' read -r line
        do
            line="$(printf '%s\n' "$line" | sed 's|^ *||g;s| *$||g')"
            if [ $_skip_empty -eq 1 -a "$line" = '' ]; then
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

join-by-delimiter () {
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
                perror 'join-by-delimiter -Ee [DELIM] [VAL1] [VAL2] ...
join-by-delimiter [--skip-empty | --keep-empty ] [DELIM] [VAL1] [VAL2] ...

can also accept stdin so you can pipe to it:

echo $'"'"'foo\n\nbar\n'"'"' | '"$0"' join-by-delimiter -E '"'\n'"'

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
        while IFS=$'\n' read -r line
        do
            if [ $_skip_empty -eq 1 -a "x${line}" = x ]; then
                continue
            fi
            if [ "x$result" = x ]; then
                result="$line"
            else
                result="$(printf "$pattern" "${result}" "${line}")"
            fi
        done < /dev/stdin
        printf '%s\n' "$result"
        return 0
    fi
    while [ $# -gt 0 ]; do
        line="$1"
        shift
        if [ $_skip_empty -eq 1 -a "x${line}" = x ]; then
            continue
        fi
        if [ "x$result" = x ]; then
            result="$line"
        else
            result="$(printf "$pattern" "${result}" "${line}")"
        fi
    done
    printf '%s\n' "$result"
}
