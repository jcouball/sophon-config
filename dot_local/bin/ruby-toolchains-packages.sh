#!/usr/bin/env bash
# Install UCRT64 packages as MSYS2 served them on a given day.
#
#   ruby-toolchains-packages.sh <yyyy-mm-dd> <cache dir> <package>...
#
# Package names are given without the mingw-w64-ucrt-x86_64- prefix. Run by
# ruby-toolchains.ps1, inside the MSYS2 it is building; that file's header
# says why a toolchain is a dated set. Must stay LF-only.
#
# MSYS2 publishes no dated snapshots, so this makes one. It reads the server's
# directory listing, takes for each package the newest file published on or
# before the day, follows the dependencies recorded inside each file, and
# hands the whole set to pacman in one transaction. pacman still does the
# checking: a set with a missing or conflicting member fails there, loudly,
# and installs nothing.
#
# Downloaded files stay in the cache directory, and so does the list of files
# each set came to (set-<day>-<id>.list). A rebuild of the same set installs
# from that list and never asks the server, which matters because MSYS2
# deletes old files without notice: once a file is gone from the listing, the
# listing would select a different version, or none. The server is asked again
# only when the list or one of its files is missing.
set -euo pipefail

day=$1
as_of=${day//-/}
cache=$2
shift 2

prefix=mingw-w64-ucrt-x86_64-
repo=https://repo.msys2.org/mingw/ucrt64
mkdir -p "$cache"

# Install with the UCRT64 repository taken out of pacman's configuration.
# pacman fills a missing dependency from its repositories without saying so,
# and from that repository it would be today's version, quietly mixed into a
# dated set. Without it, a set that is not complete fails here instead.
install_set() {
    local config
    config=$(mktemp)
    awk '/^\[/ { skip = ($0 == "[ucrt64]") } !skip' /etc/pacman.conf > "$config"
    pacman --config "$config" -U --needed --noconfirm "$@"
    local status=$?
    rm -f "$config"
    return $status
}

# A set is the day plus the packages asked for, in any order.
set_list=$cache/set-$day-$(printf '%s\n' "$@" | sort | sha256sum | cut -c1-12).list

if [ -s "$set_list" ]; then
    files=()
    complete=1
    while read -r file; do
        [ -s "$cache/$file" ] && [ -s "$cache/$file.sig" ] || { complete=0; break; }
        files+=("$cache/$file")
    done < "$set_list"
    if [ "$complete" = 1 ]; then
        echo "  Using the ${#files[@]} cached files recorded for $day"
        install_set "${files[@]}"
        exit
    fi
    echo "  The cache no longer holds every file recorded for $day; asking the server"
fi

# One line per package file: name, version, yyyymmdd, file name as the URL
# spells it. The server's directory listing is the only record of when each
# version was published. The listing percent-encodes "+" (libstdc%2B%2B); the
# name and version are decoded, the file name is kept as the server wants it.
table=$cache/index.tsv
curl -fsSL "$repo/" | awk -v prefix="$prefix" '
    BEGIN {
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", names, " ")
        for (i = 1; i <= 12; i++) month[names[i]] = sprintf("%02d", i)
    }
    match($0, /href="[^"]+-any\.pkg\.tar\.zst"/) {
        file = substr($0, RSTART + 6, RLENGTH - 7)
        if (index(file, prefix) != 1) next
        if (!match($0, /[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9]/)) next
        split(substr($0, RSTART, RLENGTH), d, "-")
        stem = substr(file, length(prefix) + 1)
        gsub(/%2B/, "+", stem)
        sub(/-any\.pkg\.tar\.zst$/, "", stem)
        n = split(stem, part, "-")
        if (n < 3) next
        name = part[1]
        for (i = 2; i <= n - 2; i++) name = name "-" part[i]
        print name "\t" part[n - 1] "-" part[n] "\t" d[3] month[d[2]] d[1] "\t" file
    }' > "$table"
[ -s "$table" ] || { echo "No packages found in the listing at $repo/" >&2; exit 1; }

# The newest version of one exact package name published on or before the
# day: prints "yyyymmdd version file", or nothing.
newest() {
    local best_date='' best_ver='' best_file='' ver date file
    while IFS=$'\t' read -r _ ver date file; do
        [ "$date" -le "$as_of" ] || continue
        # Two versions published on one day are ordered by version. A file
        # name spells an epoch "1~"; vercmp wants "1:".
        if [ -z "$best_date" ] || [ "$date" -gt "$best_date" ] ||
           { [ "$date" -eq "$best_date" ] && [ "$(vercmp "${ver/\~/:}" "${best_ver/\~/:}")" -gt 0 ]; }; then
            best_date=$date best_ver=$ver best_file=$file
        fi
    done < <(awk -F'\t' -v n="$1" '$1 == n' "$table")
    [ -n "$best_date" ] && echo "$best_date $best_ver $best_file"
    return 0
}

# MSYS2 renamed packages over the years (crt-git became crt), and a package
# can depend on a name that another one provides (winpthreads, provided by
# winpthreads-git). Of a name, the name with -git added and the name with -git
# removed, take whichever was published most recently as of the day: that is
# the one that was live.
pick() {
    local best='' found candidate
    for candidate in "$1" "$1-git" "${1%-git}"; do
        found=$(newest "$candidate")
        [ -n "$found" ] || continue
        if [ -z "$best" ] || [ "${found%% *}" -gt "${best%% *}" ]; then
            best=$found
        fi
    done
    [ -n "$best" ] && echo "$best"
    return 0
}

declare -A seen=() requested=() provided=()
for name in "$@"; do requested[$name]=1; done
files=()
virtual=()
queue=("$@")
while [ "${#queue[@]}" -gt 0 ]; do
    name=${queue[0]}
    queue=("${queue[@]:1}")
    [ -z "${seen[$name]:-}" ] || continue
    seen[$name]=1

    found=$(pick "$name")
    if [ -z "$found" ]; then
        # No file of that name. For a dependency that can be a name another
        # package provides (cc-libs, provided by gcc-libs), which is settled
        # once every package has been read.
        [ -z "${requested[$name]:-}" ] || { echo "No package $prefix$name was published on or before $day." >&2; exit 1; }
        virtual+=("$name")
        continue
    fi
    url_name=${found##* }
    file=${url_name//%2B/+}
    [ -z "${seen[$file]:-}" ] || continue
    seen[$file]=1

    # The signature comes too, so that pacman can check the file against the
    # MSYS2 signing key when it installs it.
    for suffix in '' .sig; do
        [ -s "$cache/$file$suffix" ] || {
            curl -fsSL "$repo/$url_name$suffix" -o "$cache/$file$suffix.partial"
            mv "$cache/$file$suffix.partial" "$cache/$file$suffix"
        }
    done
    files+=("$cache/$file")
    echo "  $file"

    info=$(bsdtar -xOf "$cache/$file" .PKGINFO)
    while read -r dep; do
        case $dep in "$prefix"*) queue+=("${dep#"$prefix"}") ;; esac
    done < <(sed -n 's/^depend = \([^<>=]*\).*/\1/p' <<< "$info")
    while read -r name; do
        case $name in "$prefix"*) provided[${name#"$prefix"}]=1 ;; esac
    done < <(sed -n 's/^provides = \([^<>=]*\).*/\1/p' <<< "$info")
done

for name in "${virtual[@]}"; do
    [ -n "${provided[$name]:-}" ] ||
        { echo "No package $prefix$name was published on or before $day, and nothing in the set provides it." >&2; exit 1; }
done

install_set "${files[@]}"

# Recorded only after pacman accepted the set, so a list always names a set
# that installs.
printf '%s\n' "${files[@]##*/}" > "$set_list.partial"
mv "$set_list.partial" "$set_list"
