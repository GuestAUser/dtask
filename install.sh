#!/bin/sh

set -eu

fail() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        'Usage: install.sh [--prefix PATH] [--help]' \
        '' \
        'Build and install dtask with make install; no sudo or profile changes.' \
        'Default prefix: ~/.local (executable: PREFIX/bin/dtask).' \
        '--prefix PATH overrides the PREFIX environment variable.' \
        'Environment: DC (default ldc2), PREFIX, DESTDIR, BIN_DIR (default bin).' \
        'MAKE selects the make executable (default make; use gmake on FreeBSD).' \
        'Relative prefix and staging paths are resolved from your current directory.' \
        'DC must be a single command/path; DC and BIN_DIR cannot contain spaces' \
        'or shell/make metacharacters because of the existing Makefile.' \
        'Installation paths support spaces, but not double quotes, backslashes,' \
        'dollar signs, backticks, or newlines.'
}

# Print a shell-safe command argument, including paths containing apostrophes.
shell_quote() {
    quote_rest=$1
    printf "'"

    while :; do
        case $quote_rest in
            *"'"*)
                printf "%s'\\''" "${quote_rest%%\'*}"
                quote_rest=${quote_rest#*\'}
                ;;
            *)
                printf "%s'" "$quote_rest"
                break
                ;;
        esac
    done
}

prefix=${PREFIX-}
prefix_set=${PREFIX+x}

while [ "$#" -gt 0 ]; do
    case $1 in
        --help)
            usage
            exit 0
            ;;
        --prefix)
            [ "$#" -ge 2 ] || fail '--prefix requires a path'
            prefix=$2
            prefix_set=x
            shift 2
            ;;
        *)
            fail "unknown argument: $1 (see --help)"
            ;;
    esac
done

if [ -z "$prefix_set" ]; then
    [ -n "${HOME-}" ] || fail 'HOME is unset; supply --prefix PATH'
    prefix=$HOME/.local
fi

[ -n "$prefix" ] || fail 'prefix must not be empty'
destdir=${DESTDIR-}
dc=${DC-ldc2}
bin_dir=${BIN_DIR-bin}
make_command=${MAKE-make}
invocation_dir=$(pwd -P) || fail 'cannot resolve current directory'

case $prefix in
    /*) ;;
    *) prefix=$invocation_dir/$prefix ;;
esac

case $destdir in
    ''|/*) ;;
    *) destdir=$invocation_dir/$destdir ;;
esac

# These values enter Makefile recipes. Quoting make's argv alone does not
# protect against make expansion or shell syntax embedded in recipe values.
for path in "$prefix" "$destdir"; do
    case $path in
        *'"'*|*\\*|*'$'*|*'`'*|*'
'*) fail 'installation paths contain unsupported shell/make characters' ;;
    esac
done

for value in "$dc" "$bin_dir"; do
    case $value in
        ''|*[!a-zA-Z0-9_./+@-]*)
            fail 'DC and BIN_DIR must be nonempty single paths without spaces or shell/make metacharacters'
            ;;
    esac
done

case $0 in
    */*) script=$0 ;;
    *) script=$(command -v "$0") || fail 'cannot locate install.sh' ;;
esac

script_dir=$(CDPATH='' cd -P "${script%/*}" && pwd -P) || fail 'cannot locate project directory'
cd "$script_dir" || fail 'cannot enter project directory'

for tool in "$make_command" install mkdir "$dc"; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

if ! "$make_command" install "DC=$dc" "PREFIX=$prefix" "DESTDIR=$destdir" "BIN_DIR=$bin_dir"; then
    fail "$make_command install failed; dtask was not successfully installed"
fi

installed_bin=$destdir$prefix/bin
printf 'Installed: %s/dtask\n' "$installed_bin"
printf 'Launch: '
shell_quote "$installed_bin/dtask"
printf '\n'

if [ -n "$destdir" ]; then
    printf 'Staged installation; the launch command uses the staging root.\n'
fi

# Compare PATH entries literally (not as shell patterns). Relative PATH entries
# are resolved against the invoking directory, not the project directory.
path_rest=${PATH-}
on_path=no

while :; do
    path_entry=${path_rest%%:*}

    case $path_entry in
        /*) ;;
        '') path_entry=$invocation_dir ;;
        *) path_entry=$invocation_dir/$path_entry ;;
    esac

    if [ "$path_entry" = "$installed_bin" ]; then
        on_path=yes
        break
    fi

    case $path_rest in
        *:*) path_rest=${path_rest#*:} ;;
        *) break ;;
    esac
done

if [ "$on_path" = no ]; then
    printf 'The installation bin directory is not a literal entry on PATH.\n'
    printf 'For this shell, run: export PATH='
    shell_quote "$installed_bin"
    printf '%s\n' ":\"\$PATH\"" 'Then launch: dtask'
    printf 'Equivalent directory aliases are not detected; no shell startup files were changed.\n'
else
    printf 'The installation bin directory is on PATH. Launch: dtask\n'
fi
