#!/usr/bin/env bash
# Throwaway: runs the case-only branch on real filesystems. Never merged.
#
# A refusal only counts where the folder is shown to fold first, and an
# extraction only where both files come back with their own contents.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
HZ=$REPO/target/debug/hatchzip
W=$(mktemp -d /var/tmp/fsprobe.XXXXXX)
ME=$(id -un)
MYID=$(id -u)
RESULTS=$W/results
fails=0

note() { printf '\n## %s\n' "$*"; }
say() { echo "$*" | tee -a "$RESULTS"; }
pass() { say "PASS $*"; }
fail() {
    say "FAIL $*"
    fails=$((fails + 1))
}
skip() { say "SKIP $*"; }

show_fs() { stat -f -c "$1: %T (0x%t)" "$2"; }

# Whether names differing only in case are one file in this folder.
folds() {
    local probe=$1/.probe-$RANDOM
    : >"$probe"
    local upper
    upper=$1/$(basename "$probe" | tr '[:lower:]' '[:upper:]')
    [ -e "$upper" ]
    local rc=$?
    rm -f "$probe"
    return $rc
}

mount_img() { # name size opts mkfs...
    local name=$1 size=$2 opts=$3
    shift 3
    truncate -s "$size" "$W/$name.img"
    if ! sudo "$@" "$W/$name.img" >"$W/log" 2>&1; then
        skip "$name: mkfs failed: $(tail -1 "$W/log")"
        return 1
    fi
    sudo mkdir -p "/mnt/$name"
    if ! sudo mount -o "loop$opts" "$W/$name.img" "/mnt/$name" 2>"$W/log"; then
        skip "$name: mount failed: $(tail -1 "$W/log")"
        return 1
    fi
    sudo chown "$ME" "/mnt/$name"
    show_fs "$name" "/mnt/$name"
}

expect_extracts() { # label dir archive out
    local label=$1 dir=$2 ar=$3 out=$4
    local a=$dir/a$RANDOM.tar
    cp "$ar" "$a"
    if "$HZ" extract "$a" -y --keep-free 0 -o "$out" >"$W/log" 2>&1 &&
        [ ! -e "$a" ] &&
        [ "$(cat "$out/s/Makefile" 2>/dev/null)" = a ] &&
        [ "$(cat "$out/s/makefile" 2>/dev/null)" = b ]; then
        pass "$label: extracted, both files there, archive consumed"
    else
        fail "$label: did not extract"
        cat "$W/log"
        ls -la "$out/s" 2>&1
    fi
}

expect_refused() { # label dir archive out
    local label=$1 dir=$2 ar=$3 out=$4
    local a=$dir/a$RANDOM.tar
    cp "$ar" "$a"
    local before after rc
    before=$(sha256sum <"$a")
    "$HZ" extract "$a" -y --keep-free 0 -o "$out" >"$W/log" 2>&1
    rc=$?
    after=$(sha256sum <"$a")
    if [ "$rc" -ne 0 ] && [ "$before" = "$after" ] &&
        grep -q 'differ only in case' "$W/log" &&
        [ -z "$(find "$out" -type f 2>/dev/null)" ]; then
        pass "$label: refused, archive untouched: $(tail -1 "$W/log" | cut -c1-110)"
    else
        fail "$label: rc=$rc"
        cat "$W/log"
    fi
}

# Both ways on one filesystem: `plain` must extract and `cf` must refuse, so
# a query that simply failed can't pass as a refusal.
casefold_pair() { # name mountpoint
    local name=$1 m=$2
    mkdir -p "$m/plain" "$m/cf"
    if ! chattr +F "$m/cf" 2>"$W/log"; then
        skip "$name: chattr +F failed: $(tail -1 "$W/log")"
        return 1
    fi
    if ! folds "$m/cf"; then
        fail "$name: the +F folder doesn't fold, so nothing here proves anything"
        return 1
    fi
    if folds "$m/plain"; then
        fail "$name: the plain folder folds"
        return 1
    fi
    expect_extracts "$name, plain folder" "$m/plain" "$W/case.tar" "$m/plain/o$RANDOM"
    expect_refused "$name, casefold folder" "$m/cf" "$W/case.tar" "$m/cf/o$RANDOM"
    expect_refused "$name, output not made yet below a casefold folder" \
        "$m/cf" "$W/case.tar" "$m/cf/not/yet"
}

mkdir -p "$W/src/s" "$W/src/cf" "$W/src/vol"
: >"$RESULTS"
(
    cd "$W/src" || exit 1
    echo a >s/Makefile
    echo b >s/makefile
    echo c >s/aaa
    cp s/Makefile cf/Makefile
    cp s/makefile cf/makefile
    cp s/Makefile vol/Makefile
    cp s/makefile vol/makefile
    tar -cf "$W/case.tar" s/Makefile s/makefile
    tar -cf "$W/three.tar" s/aaa s/Makefile s/makefile
    tar -cf "$W/in-cf.tar" cf
    tar -cf "$W/in-vol.tar" vol
)

note "control: main's refusal is gone only where it should be"
show_fs "runner disk" "$W"
expect_extracts "runner ext4" "$W" "$W/case.tar" "$W/o$RANDOM"

note btrfs
if mount_img btrfs 8G "" mkfs.btrfs -q; then
    folds /mnt/btrfs && fail "btrfs folds?"
    expect_extracts btrfs /mnt/btrfs "$W/case.tar" "/mnt/btrfs/o$RANDOM"
fi

note "ext4 without the casefold feature"
if mount_img ext4 8G "" mkfs.ext4 -q; then
    expect_extracts "ext4 plain" /mnt/ext4 "$W/case.tar" "/mnt/ext4/o$RANDOM"
fi

note "ext4 with casefold"
if mount_img ext4cf 8G "" mkfs.ext4 -q -O casefold -E encoding=utf8; then
    m=/mnt/ext4cf
    if casefold_pair ext4 "$m"; then
        # Point 1: the folder where the names meet decides, not the output.
        mkdir -p "$m/plain/mix/cf"
        chattr +F "$m/plain/mix/cf"
        expect_refused "ext4, names meet in a casefold subfolder of a plain output" \
            "$m/plain" "$W/in-cf.tar" "$m/plain/mix"
        expect_extracts "ext4, names meet beside that subfolder" \
            "$m/plain" "$W/case.tar" "$m/plain/mix"

        note "a run moved onto a folding folder, then back"
        mkdir -p "$m/plain/run/box" "$m/cf/run"
        ar=$m/plain/run/a.tar
        out=$m/plain/run/box/out
        cp "$W/three.tar" "$ar"
        HATCHZIP_BATCH_ENTRIES=1 HATCHZIP_CRASH_AT=after-journal \
            "$HZ" extract "$ar" -y --keep-free 0 -o "$out" >"$W/log" 2>&1
        rc=$?
        echo "crashed run: rc=$rc, output: $(ls "$out/s" 2>&1 | tr '\n' ' ')"
        [ "$rc" -ne 0 ] || fail "the crash knob didn't stop the run"
        cp -a "$m/plain/run/box" "$m/cf/run/box"
        mv "$m/plain/run/box" "$m/plain/run/box.real"
        ln -s "$m/cf/run/box" "$m/plain/run/box"
        state() { (cd "$m/plain/run" && sha256sum a.tar* && cd "$m/cf/run/box" && find . -type f -exec sha256sum {} +) | sort; }
        before=$(state)
        "$HZ" extract "$ar" -y --keep-free 0 -o "$out" >"$W/log" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ] && grep -q 'not known to keep' "$W/log" && [ "$before" = "$(state)" ]; then
            pass "resume on a folding folder: refused, nothing changed"
        else
            fail "resume on a folding folder: rc=$rc"
            cat "$W/log"
        fi
        "$HZ" restore "$ar" >"$W/log" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ] && grep -q 'not known to keep' "$W/log" && [ "$before" = "$(state)" ]; then
            pass "restore on a folding folder: refused, nothing changed"
        else
            fail "restore on a folding folder: rc=$rc"
            cat "$W/log"
        fi
        rm "$m/plain/run/box"
        mv "$m/plain/run/box.real" "$m/plain/run/box"
        "$HZ" extract "$ar" -y --keep-free 0 -o "$out" >"$W/log" 2>&1
        rc=$?
        if [ "$rc" -eq 0 ] && [ ! -e "$ar" ] &&
            [ "$(cat "$out/s/Makefile")" = a ] && [ "$(cat "$out/s/makefile")" = b ] &&
            [ "$(cat "$out/s/aaa")" = c ]; then
            pass "the same run back on the plain folder: resumed and finished"
        else
            fail "resume back on the plain folder: rc=$rc"
            cat "$W/log"
        fi
    fi
fi

note f2fs
sudo modprobe f2fs 2>/dev/null
if mount_img f2fs 2G "" mkfs.f2fs -q -O extra_attr,inode_checksum,sb_checksum,casefold -C utf8; then
    casefold_pair f2fs /mnt/f2fs
fi

note "XFS, both ways"
if mount_img xfs 8G "" mkfs.xfs -q; then
    folds /mnt/xfs && fail "plain XFS folds?"
    expect_extracts "XFS" /mnt/xfs "$W/case.tar" "/mnt/xfs/o$RANDOM"
fi
if mount_img xfsci 8G "" mkfs.xfs -q -n version=ci; then
    if folds /mnt/xfsci; then
        expect_refused "XFS version=ci" /mnt/xfsci "$W/case.tar" "/mnt/xfsci/o$RANDOM"
    else
        fail "XFS version=ci doesn't fold"
    fi
fi

note "a subfolder that is another mount"
if mountpoint -q /mnt/btrfs && mountpoint -q /mnt/xfsci; then
    out=/mnt/btrfs/mnt-out
    mkdir -p "$out/vol" /mnt/xfsci/d
    sudo mount --bind /mnt/xfsci/d "$out/vol"
    expect_refused "btrfs output, names meet in an XFS version=ci mount" \
        /mnt/btrfs "$W/in-vol.tar" "$out"
    expect_extracts "btrfs output, names meet beside that mount" \
        /mnt/btrfs "$W/case.tar" "$out"
    sudo umount "$out/vol"
else
    skip "needs btrfs and XFS version=ci"
fi

note tmpfs
sudo mkdir -p /mnt/tmp1 /mnt/tmp2
if sudo mount -t tmpfs -o "size=1G,uid=$MYID" tmpfs /mnt/tmp1; then
    show_fs tmpfs /mnt/tmp1
    expect_extracts tmpfs /mnt/tmp1 "$W/case.tar" "/mnt/tmp1/o$RANDOM"
fi
if sudo mount -t tmpfs -o "size=1G,uid=$MYID,casefold" tmpfs /mnt/tmp2 2>"$W/log"; then
    casefold_pair "tmpfs" /mnt/tmp2
else
    skip "tmpfs casefold: $(tail -1 "$W/log")"
fi

note "filesystems that aren't known stay refused"
if mount_img vfat 1G ",uid=$MYID" mkfs.vfat; then
    expect_refused vfat /mnt/vfat "$W/case.tar" "/mnt/vfat/o$RANDOM"
fi
mkdir -p "$W/ovl/lower" "$W/ovl/upper" "$W/ovl/work"
sudo mkdir -p /mnt/ovl
if sudo mount -t overlay overlay \
    -o "lowerdir=$W/ovl/lower,upperdir=$W/ovl/upper,workdir=$W/ovl/work" /mnt/ovl 2>"$W/log"; then
    sudo chown "$ME" /mnt/ovl
    show_fs overlay /mnt/ovl
    expect_refused overlay /mnt/ovl "$W/case.tar" "/mnt/ovl/o$RANDOM"
else
    skip "overlay: $(tail -1 "$W/log")"
fi

note "a real kernel tree"
V=6.12
T=linux-$V.tar.xz
cd "$W" || exit 1
if curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/$T" &&
    curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc |
    grep " $T\$" | sha256sum -c -; then
    m=/mnt/btrfs/k
    mkdir -p "$m/ref"
    tar -xf "$T" -C "$m/ref"
    files=$(find "$m/ref" -type f | wc -l)
    pairs=$(cd "$m/ref" && find . -type f | tr '[:upper:]' '[:lower:]' | sort | uniq -d | wc -l)
    echo "$files files, $pairs names that differ only in case"

    # In place, killed after a few commits, and resumed.
    cp "$T" "$m/"
    HATCHZIP_CRASH_AT=after-journal HATCHZIP_CRASH_AFTER=3 \
        "$HZ" extract "$m/$T" -y --keep-free 0 -o "$m/out" >"$W/log" 2>&1
    echo "killed run: rc=$?"
    if "$HZ" extract "$m/$T" -y --keep-free 0 -o "$m/out" >"$W/log" 2>&1 &&
        [ ! -e "$m/$T" ] && diff -r --no-dereference "$m/ref" "$m/out" >"$W/diff" 2>&1; then
        pass "kernel $V on btrfs, in place, killed and resumed: same tree as tar, $files files, $pairs pairs"
    else
        fail "kernel $V on btrfs"
        tail -5 "$W/log"
        head -20 "$W/diff"
    fi
    rm -rf "$m/out"

    if mountpoint -q /mnt/xfs; then
        cp "$T" /mnt/xfs/
        if "$HZ" extract "/mnt/xfs/$T" -y --keep-free 0 -o /mnt/xfs/out >"$W/log" 2>&1 &&
            diff -r --no-dereference "$m/ref" /mnt/xfs/out >"$W/diff" 2>&1; then
            pass "kernel $V on XFS, in place: same tree as tar"
        else
            fail "kernel $V on XFS"
            tail -5 "$W/log"
            head -20 "$W/diff"
        fi
        rm -rf /mnt/xfs/out
    fi
else
    skip "kernel tarball not available or checksum mismatch"
fi

note "the layout and journal suites with the temp folder on each"
cd "$REPO" || exit 1
for d in /mnt/btrfs/tmp /mnt/xfs/tmp /mnt/xfsci/tmp /mnt/ext4cf/cf/tmp; do
    parent=$(dirname "$d")
    mountpoint -q "$parent" || [ -d "$parent" ] || {
        skip "suites on $d"
        continue
    }
    mkdir -p "$d"
    if TMPDIR=$d cargo test -p hatchzip --test layout --test journal --locked >"$W/log" 2>&1; then
        pass "suites on $d: $(grep -E '^test result' "$W/log" | awk '{p += $4} END {print p " passed"}')"
    else
        fail "suites on $d"
        grep -E '^(test result|---- |failures:)|FAILED|panicked' "$W/log" | head -30
    fi
done

note results
cat "$RESULTS"
echo "failures: $fails"
[ "$fails" -eq 0 ]
