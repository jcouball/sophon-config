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
# listing would select a different version, or none.
#
# A machine with no cache has no list. For that, RUBY_TOOLCHAIN_ARCHIVE names
# a place that keeps a copy of each set as one file, set-<day>-<id>.tar,
# holding the list and every file it names. When the cache cannot supply a
# set, that copy is tried before the server, because it is the set a toolchain
# was already built from and the server may no longer be able to produce it.
# The server is asked only when there is no copy, or the copy is refused, or
# installing from it leaves a requested package out.
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

# Fill `files` from the set's list. Fails when there is no list, or the cache
# lacks a file the list names or its signature.
cached_set() {
    local file
    files=()
    [ -s "$set_list" ] || return 1
    while read -r file; do
        [ -s "$cache/$file" ] && [ -s "$cache/$file.sig" ] || return 1
        files+=("$cache/$file")
    done < "$set_list"
}

# The requested packages that are not installed, on one line. A package may
# be installed under the name with -git added or removed, as pick() below
# explains, so each of the three is asked about.
not_installed() {
    local name candidate found
    for name in "$@"; do
        found=0
        for candidate in "$name" "$name-git" "${name%-git}"; do
            if pacman -T "$prefix$candidate" > /dev/null 2>&1; then found=1; break; fi
        done
        [ "$found" = 1 ] || printf '%s ' "$name"
    done
}

# Install the files cached_set found, then check that the packages asked for
# are all there. A list is only as good as whoever wrote it: one that leaves a
# package out installs cleanly and would be taken for the whole set. Such a
# list is deleted, and the caller goes on to the next source.
install_recorded() {
    local missing
    install_set "${files[@]}" || exit
    missing=$(not_installed "${requested_names[@]}")
    [ -n "$missing" ] || exit 0
    echo "  The recorded set leaves these not installed: $missing"
    rm -f "$set_list"
    return 1
}

# Whether a signature is a valid one for a file, made by a key pacman's
# keyring trusts. This is the check `pacman-key --verify` makes; that command
# itself refuses to run here, over the permissions of the keyring folder.
signed_by_msys2() {
    local status
    status=$(gpg --homedir /etc/pacman.d/gnupg --batch --no-tty --status-fd 1 --verify "$1" "$2" 2> /dev/null) || return 1
    grep -q '^\[GNUPG:\] VALIDSIG ' <<< "$status" &&
        grep -qE '^\[GNUPG:\] TRUST_(FULLY|ULTIMATE) ' <<< "$status"
}

# The file name MSYS2 gives a package, worked out from what the package says
# it is. A signature only shows that MSYS2 built a file, not which one: another
# genuine package under this name would pass it. A file name spells an epoch
# "1~" where the package says "1:".
package_file_name() {
    bsdtar -xOf "$1" .PKGINFO 2> /dev/null | awk -F' = ' '
        $1 == "pkgname" { name = $2 }
        $1 == "pkgver" { version = $2 }
        $1 == "arch" { arch = $2 }
        END { sub(/:/, "~", version); print name "-" version "-" arch ".pkg.tar.zst" }'
}

# Fetch the copy of this set and let it into the cache. Fails, leaving the
# cache as it was, unless the copy is a flat archive of ordinary files that
# holds the set's list and every package the list names, each with a
# signature that verifies against MSYS2's key and each the package its file
# name says it is.
#
# The copy is unpacked beside the cache and checked there. A file that was
# unpacked straight into the cache would be found by cached_set on every later
# run, so one bad package would stop this set being built until somebody
# deleted it by hand. A file the cache already holds is never replaced.
fetch_copy() {
    local name=${set_list##*/}
    name=${name%.list}
    local tar=$cache/$name.tar.partial
    local stage=$cache/.copy-$name
    local plain='^[A-Za-z0-9@._+~-]+$'
    local listing names file suffix

    refuse() {
        rm -rf "$tar" "$stage"
        echo "  $1"
        return 1
    }

    echo "  Looking for a copy of the set at $RUBY_TOOLCHAIN_ARCHIVE/$name.tar"
    curl -fsSL "$RUBY_TOOLCHAIN_ARCHIVE/$name.tar" -o "$tar" ||
        { refuse 'There is no copy to download'; return 1; }

    # The long listing starts each line with the entry's type: "-" for an
    # ordinary file. A link could point a later write somewhere else.
    listing=$(bsdtar -tvf "$tar") ||
        { refuse 'The copy is not a tar archive'; return 1; }
    ! grep -qv '^-' <<< "$listing" ||
        { refuse 'The copy holds something that is not an ordinary file; not unpacking it'; return 1; }
    # The names are read into a variable first. In a pipeline, grep stopping
    # at the first bad name would end bsdtar early, and with pipefail that
    # failure would be taken for "no bad name found".
    names=$(bsdtar -tf "$tar") ||
        { refuse 'The copy is not a tar archive'; return 1; }
    ! grep -qvE "$plain" <<< "$names" ||
        { refuse 'The copy holds a name that is not a plain file name; not unpacking it'; return 1; }

    rm -rf "$stage"
    mkdir "$stage"
    bsdtar -xf "$tar" -C "$stage" ||
        { refuse 'The copy could not be unpacked'; return 1; }
    rm -f "$tar"

    [ -s "$stage/$name.list" ] ||
        { refuse 'The copy does not hold the list of its files'; return 1; }
    while read -r file; do
        [[ $file =~ $plain ]] ||
            { refuse 'The list in the copy holds a name that is not a plain file name'; return 1; }
        [ -s "$stage/$file" ] && [ -s "$stage/$file.sig" ] ||
            { refuse "The copy does not hold the whole set: $file or its signature is missing"; return 1; }
        signed_by_msys2 "$stage/$file.sig" "$stage/$file" ||
            { refuse "The signature of $file in the copy does not verify"; return 1; }
        [ "$(package_file_name "$stage/$file")" = "$file" ] ||
            { refuse "The copy's $file is not the package its name says"; return 1; }
    done < "$stage/$name.list"

    while read -r file; do
        for suffix in '' .sig; do
            [ -s "$cache/$file$suffix" ] || mv "$stage/$file$suffix" "$cache/$file$suffix"
        done
    done < "$stage/$name.list"
    # The list goes in last, so a run stopped before here leaves no list
    # that names files the cache lacks.
    mv "$stage/$name.list" "$set_list"
    rm -rf "$stage"
}

requested_names=("$@")

if cached_set; then
    echo "  Using the ${#files[@]} cached files recorded for $day"
    install_recorded || true
elif [ -s "$set_list" ]; then
    echo "  The cache no longer holds every file recorded for $day"
fi

if [ -n "${RUBY_TOOLCHAIN_ARCHIVE:-}" ] && fetch_copy && cached_set; then
    echo "  Using the ${#files[@]} files of the downloaded copy"
    install_recorded || true
fi
echo "  Asking the MSYS2 server"

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
