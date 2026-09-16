#!/usr/bin/env bash
# Test suite for sort-photos.sh
set -uo pipefail

# override with: SCRIPT=/path/to/sort-photos.sh ./run-tests.sh
SCRIPT=${SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sort-photos.sh}
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fakebin:$PATH"
WORK=$(mktemp -d /tmp/pstest.XXXXXX)
pass=0; fail=0; cur=""

t() { cur=${1:-}; rm -rf "$WORK"/*; mkdir -p "$WORK/src" "$WORK/tgt"; }
ok()   { ((++pass)); printf '  ok   %s\n' "$1"; }
no()   { ((++fail)); printf '  FAIL %s\n' "$1"; }
have() { if [[ -e "$WORK/$1" ]]; then ok "exists: $1"; else no "missing: $1"; ls -R "$WORK" | sed 's/^/       /'; fi; }
gone() { if [[ -e "$WORK/$1" ]]; then no "should not exist: $1"; else ok "absent: $1"; fi; }
count() { local n; n=$(find "$WORK/$2" -type f 2>/dev/null | wc -l); if [[ $n == "$1" ]]; then ok "$2 has $1 file(s)"; else no "$2 has $n file(s), expected $1"; find "$WORK/$2" -type f | sed 's/^/       /'; fi; }
grepout() { if grep -qE -- "$1" "$WORK/out.txt"; then ok "output matches /$1/"; else no "output lacks /$1/"; sed 's/^/       /' "$WORK/out.txt"; fi; }
nogrepout() { if grep -qE -- "$1" "$WORK/out.txt"; then no "output unexpectedly matches /$1/"; sed 's/^/       /' "$WORK/out.txt"; else ok "output free of /$1/"; fi; }

mk() { # mk <relpath> <EXIF date or "-"> [content salt]
	local p="$WORK/$1" d=$2 salt=${3:-}
	mkdir -p "${p%/*}"
	if [[ $d == - ]]; then printf 'plain%s\n' "$salt" >"$p"
	elif [[ $d == C:* ]]; then printf 'EXIFC:%s\n%s\n' "${d#C:}" "$salt" >"$p"
	else printf 'EXIF:%s\n%s\n' "$d" "$salt" >"$p"; fi
}
run() { "$SCRIPT" -t "$WORK/tgt" "$@" >"$WORK/out.txt" 2>&1; echo $? >"$WORK/rc.txt"; }

section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
section "1. basic sorting, year/month folders, EXIF name"
t
mk src/a.jpg '2021-07-15 14:23:11'
mk src/b.JPG '2019-01-02 03:04:05'
mk src/sub/c.jpg 'C:2021-07-16 08:00:00'      # date from CreateDate, not DTO
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2019/01/2019-01-02 03.04.05.JPG'
have 'tgt/2021/07/2021-07-16 08.00.00.jpg'
count 0 src
grepout 'date from EXIF       3'

section "2. no EXIF -> filesystem date fallback"
t
mk src/noexif.jpg -
touch -t 200503041530.45 "$WORK/src/noexif.jpg"
run -s "$WORK/src" --fallback mtime
have 'tgt/2005/03/2005-03-04 15.30.45.jpg'
grepout 'date from filesystem 1'

section "3. garbage EXIF date (0000) falls back too"
t
mk src/zero.jpg '0000-00-00 00:00:00'
touch -t 201102030405.06 "$WORK/src/zero.jpg"
run -s "$WORK/src" --fallback mtime
have 'tgt/2011/02/2011-02-03 04.05.06.jpg'

section "4. same timestamp, different content -> (1), (2)"
t
mk src/x1.jpg '2020-05-05 10:00:00' one
mk src/x2.jpg '2020-05-05 10:00:00' two
mk src/x3.jpg '2020-05-05 10:00:00' three
run -s "$WORK/src"
have 'tgt/2020/05/2020-05-05 10.00.00.jpg'
have 'tgt/2020/05/2020-05-05 10.00.00 (1).jpg'
have 'tgt/2020/05/2020-05-05 10.00.00 (2).jpg'
count 3 tgt

section "5. identical content: default keep -> (1)"
t
mk src/d1.jpg '2020-05-05 10:00:00' same
mk src/d2.jpg '2020-05-05 10:00:00' same
run -s "$WORK/src"
count 2 tgt
grepout 'duplicates found     1'

section "6. --dedupe skip leaves the duplicate in the source"
t
mk src/d1.jpg '2020-05-05 10:00:00' same
mk src/d2.jpg '2020-05-05 10:00:00' same
run -s "$WORK/src" --dedupe skip
count 1 tgt
count 1 src
grepout 'duplicates skipped   1'

section "7. --dedupe delete removes it"
t
mk src/d1.jpg '2020-05-05 10:00:00' same
mk src/d2.jpg '2020-05-05 10:00:00' same
run -s "$WORK/src" --dedupe delete --yes
count 1 tgt
count 0 src
grepout 'duplicates deleted   1'

section "8. --dedupe delete refuses to run unattended without --yes"
t
mk src/d1.jpg '2020-05-05 10:00:00' same
mk src/d2.jpg '2020-05-05 10:00:00' same
run -s "$WORK/src" --dedupe delete
count 0 tgt
count 2 src
grepout 'pass --yes'

section "9. existing target files are reorganised, correct ones untouched"
t
mk 'tgt/2021/07/2021-07-15 14.23.11.jpg' '2021-07-15 14:23:11' already   # already right
mk tgt/loose/IMG_9999.jpg '2018-11-30 22:10:00' loose                    # wrong place
mk tgt/2000/01/wrongname.jpg '2018-11-30 22:11:00' other                 # wrong name+place
mk src/new.jpg '2018-11-30 22:12:00' new
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2018/11/2018-11-30 22.10.00.jpg'
have 'tgt/2018/11/2018-11-30 22.11.00.jpg'
have 'tgt/2018/11/2018-11-30 22.12.00.jpg'
gone tgt/loose/IMG_9999.jpg
grepout 'already in place     1'

section "10. --no-reorganize leaves the target alone"
t
mk tgt/loose/IMG_9999.jpg '2018-11-30 22:10:00' loose
mk src/new.jpg '2018-11-30 22:12:00' new
run -s "$WORK/src" --no-reorganize
have tgt/loose/IMG_9999.jpg
have 'tgt/2018/11/2018-11-30 22.12.00.jpg'

section "11. name swap inside the target (needs staging)"
t
# a.jpg currently holds the name that b.jpg must get, and vice versa
mk 'tgt/2020/05/2020-05-05 10.00.00.jpg' '2020-05-05 11:00:00' aaa
mk 'tgt/2020/05/2020-05-05 11.00.00.jpg' '2020-05-05 10:00:00' bbb
run -s "$WORK/src"
count 2 tgt
if [[ $(sed -n 2p "$WORK/tgt/2020/05/2020-05-05 11.00.00.jpg") == aaa ]]; then ok "swap: 11.00.00 holds aaa"; else no "swap: wrong content in 11.00.00"; fi
if [[ $(sed -n 2p "$WORK/tgt/2020/05/2020-05-05 10.00.00.jpg") == bbb ]]; then ok "swap: 10.00.00 holds bbb"; else no "swap: wrong content in 10.00.00"; fi
nogrepout 'FAILED'

section "12. chained rename inside the target"
t
mk 'tgt/2020/05/2020-05-05 10.00.00.jpg' '2020-05-05 11:00:00' aaa
mk 'tgt/2020/05/2020-05-05 11.00.00.jpg' '2020-05-05 12:00:00' bbb
mk 'tgt/2020/05/2020-05-05 12.00.00.jpg' '2020-05-05 13:00:00' ccc
run -s "$WORK/src"
count 3 tgt
have 'tgt/2020/05/2020-05-05 11.00.00.jpg'
have 'tgt/2020/05/2020-05-05 12.00.00.jpg'
have 'tgt/2020/05/2020-05-05 13.00.00.jpg'

section "13. --no-rename keeps names, still resolves clashes"
t
mk src/a/photo.jpg '2020-05-05 10:00:00' one
mk src/b/photo.jpg '2020-05-05 11:00:00' two
run -s "$WORK/src" --no-rename
have tgt/2020/05/photo.jpg
have 'tgt/2020/05/photo (1).jpg'

section "14. custom --name-format and --dir-format"
t
mk src/a.jpg '2021-07-15 14:23:11'
run -s "$WORK/src" --dir-format '%Y/%Y-%m' --name-format 'IMG_%Y%m%d_%H%M%S'
have 'tgt/2021/2021-07/IMG_20210715_142311.jpg'

section "15. --copy keeps the source"
t
mk src/a.jpg '2021-07-15 14:23:11'
run -s "$WORK/src" --copy
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have src/a.jpg
grepout 'copied               1'

section "16. --dry-run changes nothing but reports"
t
mk src/a.jpg '2021-07-15 14:23:11' one
mk src/b.jpg '2021-07-15 14:23:11' one     # duplicate content
mk src/c.jpg '2021-07-15 14:23:11' three   # name clash
run -s "$WORK/src" -n
count 0 tgt
count 3 src
grepout 'dry run'
grepout 'to move              3'
grepout 'duplicates found     1'

section "17. --dry-run duplicate/delete accounting"
t
mk src/a.jpg '2021-07-15 14:23:11' one
mk src/b.jpg '2021-07-15 14:23:11' one
run -s "$WORK/src" -n --dedupe delete
grepout 'duplicates to delete 1'
count 2 src

section "18. multiple sources"
t
mkdir -p "$WORK/src2"
mk src/a.jpg '2021-07-15 14:23:11'
mk src2/b.jpg '2022-08-16 15:24:12'
run -s "$WORK/src" -s "$WORK/src2"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2022/08/2022-08-16 15.24.12.jpg'

section "19. --fallback unsorted / skip"
t
mk src/nodate.jpg -
run -s "$WORK/src" --fallback unsorted
have tgt/Unsorted/nodate.jpg
t
mk src/nodate.jpg -
run -s "$WORK/src" --fallback skip
have src/nodate.jpg
count 0 tgt

section "19b. --fallback oldest prefers the older of birth/mtime"
t
mk src/nodate.jpg -                                  # birth = now
touch -t 200101010101.01 "$WORK/src/nodate.jpg"      # mtime = long ago
run -s "$WORK/src" --fallback oldest
have 'tgt/2001/01/2001-01-01 01.01.01.jpg'

section "20. --sidecars follow their photo"
t
mk src/IMG_1.CR2 '2021-07-15 14:23:11'
printf 'xmp\n' >"$WORK/src/IMG_1.xmp"
printf 'xmp2\n' >"$WORK/src/IMG_1.CR2.xmp"
run -s "$WORK/src" --sidecars
have 'tgt/2021/07/2021-07-15 14.23.11.CR2'
have 'tgt/2021/07/2021-07-15 14.23.11.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
count 0 src

section "20b. darktable: raw + primary xmp + duplicate edits"
t
mk src/IMG_7605.CR2 '2021-07-15 14:23:11'
printf 'main\n' >"$WORK/src/IMG_7605.CR2.xmp"
printf 'dup1\n' >"$WORK/src/IMG_7605_01.CR2.xmp"
printf 'dup2\n' >"$WORK/src/IMG_7605_02.CR2.xmp"
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.CR2'
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_02.CR2.xmp'
count 0 src
grepout 'sidecars             3'
# the edits must still point at a photo that is actually there
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp") == dup1 ]]; then ok "dup1 content intact"; else no "dup1 content wrong"; fi

section "20c. sidecars are on by default, --no-sidecars turns them off"
t
mk src/IMG_1.CR2 '2021-07-15 14:23:11'
printf 'x\n' >"$WORK/src/IMG_1.CR2.xmp"
run -s "$WORK/src"                       # no --sidecars flag given
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
t
mk src/IMG_1.CR2 '2021-07-15 14:23:11'
printf 'x\n' >"$WORK/src/IMG_1.CR2.xmp"
run -s "$WORK/src" --no-sidecars
have src/IMG_1.CR2.xmp
have 'tgt/2021/07/2021-07-15 14.23.11.CR2'

section "20d. another photo's sidecar is not stolen"
t
mk src/IMG_1.CR2 '2021-07-15 14:23:11' a
mk src/IMG_1_02.CR2 '2022-08-16 15:24:12' b      # a real photo, not a duplicate edit
printf 'mine\n' >"$WORK/src/IMG_1.CR2.xmp"
printf 'theirs\n' >"$WORK/src/IMG_1_02.CR2.xmp"
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
have 'tgt/2022/08/2022-08-16 15.24.12.CR2.xmp'
if [[ $(sed -n 1p "$WORK/tgt/2022/08/2022-08-16 15.24.12.CR2.xmp") == theirs ]]; then ok "sidecar stayed with its own photo"; else no "sidecar was stolen"; fi
count 0 src

section "20e. non-numbered stem variants are left alone"
t
mk src/IMG_1.CR2 '2021-07-15 14:23:11'
printf 'notmine\n' >"$WORK/src/IMG_1_backup.xmp"
run -s "$WORK/src"
have src/IMG_1_backup.xmp

section "20f. sidecars follow a dateless photo into Unsorted"
t
mk src/IMG_9.CR2 -
printf 'x\n' >"$WORK/src/IMG_9.CR2.xmp"
run -s "$WORK/src" --fallback unsorted
have tgt/Unsorted/IMG_9.CR2
have tgt/Unsorted/IMG_9.CR2.xmp

section "20g. sidecars of a duplicate: --dedupe keep follows the (1) photo"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11 (1).CR2.xmp'
count 4 tgt
count 0 src

section "20h. --dedupe skip leaves the duplicate AND its sidecar alone"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe skip
count 2 tgt
have src/IMG_B.CR2
have src/IMG_B.CR2.xmp

section "20i. --dedupe delete: a DIFFERENT edit is kept as another version"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete --yes
have 'tgt/2021/07/2021-07-15 14.23.11.CR2'
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
count 0 src                                  # nothing orphaned
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp") == edit-B ]]; then ok "the differing edit survived"; else no "edit-B lost"; fi
gone 'tgt/2021/07/2021-07-15 14.23.11 (1).CR2'

section "20j. --dedupe delete: an IDENTICAL edit is deleted with the photo"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-same\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-same\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete --yes
count 2 tgt
count 0 src
gone 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
grepout 'their sidecars       1 \(deleted as well\)'

section "20k. --dup-sidecars delete and keep"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete --dup-sidecars delete --yes
count 2 tgt
count 0 src
gone 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete --dup-sidecars keep --yes
have src/IMG_B.CR2.xmp
grepout 'left where it is'

section "20l. duplicate's sidecar takes the primary slot if the survivor has none"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'only-edit\n' >"$WORK/src/IMG_B.CR2.xmp"       # survivor A has no sidecar
run -s "$WORK/src" --dedupe delete --yes
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
gone 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11.CR2.xmp") == only-edit ]]; then ok "edit kept in the primary slot"; else no "wrong content"; fi

section "20m. next free slot when _01 is already used"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-A-dup\n' >"$WORK/src/IMG_A_01.CR2.xmp"   # survivor already has a _01
printf 'edit-B\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete --yes
have 'tgt/2021/07/2021-07-15 14.23.11.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.CR2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_02.CR2.xmp'
count 0 src
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11_02.CR2.xmp") == edit-B ]]; then ok "edit-B landed in _02"; else no "wrong slot content"; fi

section "20n. dry run accounts for the sidecar deletions and asks about them"
t
mk src/IMG_A.CR2 '2021-07-15 14:23:11' same
mk src/IMG_B.CR2 '2021-07-15 14:23:11' same
printf 'edit-same\n' >"$WORK/src/IMG_A.CR2.xmp"
printf 'edit-same\n' >"$WORK/src/IMG_B.CR2.xmp"
run -s "$WORK/src" --dedupe delete -n
grepout 'their sidecars       1 \(to delete as well\)'
count 0 tgt
run -s "$WORK/src" --dedupe delete          # no --yes, not a terminal
grepout 'would delete 2 file'
count 4 src

section "20o. bad --dup-sidecars value"
t
run -s "$WORK/src" --dup-sidecars wat; grepout '--dup-sidecars must be'

section "20p. --dedupe-scope all finds copies the name scope cannot"
t
mk src/IMG_3024.CR2 '2021-07-15 14:23:11' same
mk src/IMG_3024\(1\).cr2 '2021-07-15 14:23:11' same     # extension case differs
run -s "$WORK/src"
grepout 'duplicates found     0'                        # default scope: missed
t
mk src/IMG_3024.CR2 '2021-07-15 14:23:11' same
mk src/IMG_3024\(1\).cr2 '2021-07-15 14:23:11' same
run -s "$WORK/src" --dedupe-scope all
grepout 'duplicates found     1'
t
mk src/IMG_3024.jpg '2021-07-15 14:23:11' same
mk src/IMG_3024-Copy\(1\).jpeg '2021-07-15 14:23:11' same
run -s "$WORK/src" --dedupe-scope all
grepout 'duplicates found     1'

section "20q. --dedupe-scope all works with --no-rename too"
t
mk src/IMG_3024.CR2 '2021-07-15 14:23:11' same
mk src/IMG_3024\(1\).CR2 '2021-07-15 14:23:11' same
run -s "$WORK/src" --no-rename
grepout 'duplicates found     0'
t
mk src/IMG_3024.CR2 '2021-07-15 14:23:11' same
mk src/IMG_3024\(1\).CR2 '2021-07-15 14:23:11' same
run -s "$WORK/src" --no-rename --dedupe-scope all --dedupe delete --yes
count 1 tgt
count 0 src

section "20r. --dedupe-scope all: 3 copies leave one, and stay stable"
t
mk src/a.jpg '2021-07-15 14:23:11' same
mk src/b.JPG '2021-07-15 14:23:11' same
mk src/c.jpeg '2021-07-15 14:23:11' same
run -s "$WORK/src" --dedupe-scope all --dedupe delete --yes
count 1 tgt
count 0 src
grepout 'duplicates found     2'
before=$(find "$WORK/tgt" -type f | sort)
run -s "$WORK/src" --dedupe-scope all
[[ $before == "$(find "$WORK/tgt" -type f | sort)" ]] && ok "stable on re-run" || no "re-run changed things"

section "20s. --dedupe-scope all keeps the library copy, not the import"
t
mk 'tgt/2021/07/2021-07-15 14.23.11.CR2' '2021-07-15 14:23:11' same    # already sorted
mk src/IMG_3024.cr2 '2021-07-15 14:23:11' same                          # a stray copy
run -s "$WORK/src" --dedupe-scope all --dedupe delete --yes
have 'tgt/2021/07/2021-07-15 14.23.11.CR2'
count 1 tgt
count 0 src

section "20t. --dedupe-scope all rescues an edit across differing extensions"
t
mk src/IMG_3024.JPG '2021-07-15 14:23:11' same
mk src/IMG_3024-Copy\(1\).jpeg '2021-07-15 14:23:11' same
printf 'edit-A\n' >"$WORK/src/IMG_3024.JPG.xmp"
printf 'edit-B\n' >"$WORK/src/IMG_3024-Copy(1).jpeg.xmp"
run -s "$WORK/src" --dedupe-scope all --dedupe delete --yes
count 0 src
# IMG_3024.JPG wins the election (shortest name), so .JPG is the surviving ext
have 'tgt/2021/07/2021-07-15 14.23.11.JPG'
have 'tgt/2021/07/2021-07-15 14.23.11.JPG.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.JPG.xmp'
count 3 tgt
# the rescued sidecar must carry the SURVIVOR's extension, not the duplicate's
gone 'tgt/2021/07/2021-07-15 14.23.11_01.jpeg.xmp'
gone 'tgt/2021/07/2021-07-15 14.23.11.JPG.jpeg.xmp'
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11.JPG.xmp") == edit-A ]]; then ok "survivor's own edit stayed primary"; else no "wrong primary content"; fi
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11_01.JPG.xmp") == edit-B ]]; then ok "the duplicate's edit was rescued"; else no "wrong rescued content"; fi

section "20u. --dedupe-scope all with keep and skip"
t
mk src/a.jpg '2021-07-15 14:23:11' same
mk src/b.jpeg '2021-07-15 14:23:11' same
run -s "$WORK/src" --dedupe-scope all             # keep is the default
count 2 tgt
grepout 'duplicates found     1'
t
mk src/a.jpg '2021-07-15 14:23:11' same
mk src/b.jpeg '2021-07-15 14:23:11' same
run -s "$WORK/src" --dedupe-scope all --dedupe skip
count 1 tgt
count 1 src
grepout 'duplicates skipped   1'

section "20w. when both copies are in the target, the clean name survives"
for pair in 'IMG_2034-copy(1).cr2' 'IMG_2034 (1).cr2' 'Copy of IMG_2034.cr2' 'IMG_2034 - Kopie.cr2'; do
	t
	mk 'tgt/IMG_2034.cr2' '2021-07-15 14:23:11' same
	mk "tgt/$pair" '2021-07-15 14:23:11' same
	"$SCRIPT" "$WORK/tgt" --dedupe-scope all --dedupe delete --yes --no-rename >"$WORK/out.txt" 2>&1
	if [[ -e "$WORK/tgt/2021/07/IMG_2034.cr2" ]]; then ok "kept IMG_2034.cr2 over \"$pair\""
	else no "wrong survivor against \"$pair\": $(find "$WORK/tgt" -type f -printf '%P')"; fi
	count 1 tgt
done

section "20x. the already-filed photo wins and keeps its sidecar as primary"
t
mk 'tgt/2021/07/2021-07-15 14.23.11.cr2' '2021-07-15 14:23:11' same        # already filed
mk 'tgt/2021/07/2021-07-15 14.23.11-copy.cr2' '2021-07-15 14:23:11' same   # a copy of it
printf 'the-real-edit\n' >"$WORK/tgt/2021/07/2021-07-15 14.23.11.cr2.xmp"
printf 'the-copys-edit\n' >"$WORK/tgt/2021/07/2021-07-15 14.23.11-copy.cr2.xmp"
"$SCRIPT" "$WORK/tgt" --dedupe-scope all --dedupe delete --yes >"$WORK/out.txt" 2>&1
have 'tgt/2021/07/2021-07-15 14.23.11.cr2'
have 'tgt/2021/07/2021-07-15 14.23.11.cr2.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.cr2.xmp'
count 3 tgt
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11.cr2.xmp") == the-real-edit ]]; then ok "the filed photo's own edit stayed primary"; else no "primary sidecar was overwritten"; fi
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11_01.cr2.xmp") == the-copys-edit ]]; then ok "the copy's edit was preserved"; else no "copy's edit lost"; fi
gone 'tgt/2021/07/2021-07-15 14.23.11 (1).cr2.xmp'

section "20y. a survivor's own sidecar is never deleted as a self-duplicate"
t
mk 'tgt/2021/07/2021-07-15 14.23.11.cr2' '2021-07-15 14:23:11' same
mk 'tgt/loose/IMG_1.cr2' '2021-07-15 14:23:11' same
printf 'only-edit\n' >"$WORK/tgt/2021/07/2021-07-15 14.23.11.cr2.xmp"
"$SCRIPT" "$WORK/tgt" --dedupe-scope all --dedupe delete --yes >"$WORK/out.txt" 2>&1
have 'tgt/2021/07/2021-07-15 14.23.11.cr2.xmp'
if [[ $(sed -n 1p "$WORK/tgt/2021/07/2021-07-15 14.23.11.cr2.xmp") == only-edit ]]; then ok "edit intact"; else no "edit lost"; fi
count 2 tgt

section "20z. shortest name wins when neither copy is filed correctly"
t
mk 'tgt/loose/IMG_2034.cr2' '2021-07-15 14:23:11' same
mk 'tgt/loose/IMG_2034 - Copy (1).cr2' '2021-07-15 14:23:11' same
"$SCRIPT" "$WORK/tgt" --dedupe-scope all --dedupe delete --yes --no-rename >"$WORK/out.txt" 2>&1
have tgt/2021/07/IMG_2034.cr2
count 1 tgt

section "20v. bad --dedupe-scope values"
t
run -s "$WORK/src" --dedupe-scope wat; grepout '--dedupe-scope must be'
run -s "$WORK/src" --dedupe-scope all --hash none; grepout 'needs hashing'

section "34. --cache reuses dates and notices changes"
t
mk src/a.jpg '2021-07-15 14:23:11'
mk src/b.jpg '2019-01-02 03:04:05'
run -s "$WORK/src" --cache "$WORK/c.tsv"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
if [[ $(grep -cv '^#' "$WORK/c.tsv") == 2 ]]; then ok "cache holds 2 entries"; else no "cache has $(grep -cv '^#' "$WORK/c.tsv") entries"; fi
# a second pass over the same library must reuse them and touch nothing
run "$WORK/tgt" --cache "$WORK/c.tsv"
grepout '2 file\(s\) unchanged since the last run'
grepout 'already in place     2'
nogrepout 'reading EXIF from'
# and the cache must be keyed on content, not just the path
printf 'EXIF:2001-02-03 04:05:06\nchanged\n' >"$WORK/tgt/2021/07/2021-07-15 14.23.11.jpg"
run "$WORK/tgt" --cache "$WORK/c.tsv"
grepout 'reading EXIF from 1 file'
have 'tgt/2001/02/2001-02-03 04.05.06.jpg'

section "34b. --no-reorganize only looks at the incoming files"
t
for i in 1 2 3 4 5; do mk "tgt/2019/01/2019-01-0$i 03.04.05.jpg" "2019-01-0$i 03:04:05" "lib$i"; done
mk src/new.jpg '2021-07-15 14:23:11'
run -s "$WORK/src" --no-reorganize
grepout 'scanning 1 file'
count 6 tgt
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
# the default really does scan the whole library, for contrast
run -s "$WORK/src" -n
grepout 'scanning 6 file'

section "34c. a photo whose local time does not exist (DST spring forward)"
t
mk src/dst.jpg '2022-03-27 02:02:14'
mk src/dst2.jpg '2021-03-28 02:30:00'
run -s "$WORK/src"
have 'tgt/2022/03/2022-03-27 02.02.14.jpg'
have 'tgt/2021/03/2021-03-28 02.30.00.jpg'
nogrepout 'problems'
nogrepout 'cannot make sense'

section "21. extension filter and --all-files"
t
mk src/a.jpg '2021-07-15 14:23:11'
mk src/notes.doc -
run -s "$WORK/src"
have src/notes.doc
t
mk src/a.jpg '2021-07-15 14:23:11'
mk src/b.mp4 '2021-07-15 14:23:12'
run -s "$WORK/src" --ext jpg
have src/b.mp4
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'

section "22. --lower-ext, --prune-empty, --log"
t
mk src/deep/nested/a.JPG '2021-07-15 14:23:11'
run -s "$WORK/src" --lower-ext --prune-empty --log "$WORK/sort.log"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
gone src/deep
if grep -q 'move' "$WORK/sort.log"; then ok "log written"; else no "log missing"; fi

section "23. spaces, quotes and unicode in names"
t
mk "src/my photo's [1] Ünïcödé.jpg" '2021-07-15 14:23:11'
mk 'src/tricky $(rm -rf).jpg' '2021-07-15 14:23:12'
run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.12.jpg'
count 0 src

section "24. source inside the target is not processed twice"
t
mkdir -p "$WORK/tgt/inbox"
mk tgt/inbox/a.jpg '2021-07-15 14:23:11'
run -s "$WORK/tgt/inbox"
count 1 tgt
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'

section "25. idempotent: running twice changes nothing"
t
mk src/a.jpg '2021-07-15 14:23:11' one
mk src/b.jpg '2021-07-15 14:23:11' two
run -s "$WORK/src"
before=$(find "$WORK/tgt" -type f | sort)
run -s "$WORK/src"
after=$(find "$WORK/tgt" -type f | sort)
if [[ $before == "$after" ]]; then ok "second run is a no-op"; else no "second run changed the library"; diff <(echo "$before") <(echo "$after") | sed 's/^/       /'; fi
grepout 'already in place     2'

section "26. no exiftool at all -> filesystem dates, still works"
t
mk src/a.jpg '2021-07-15 14:23:11'
touch -t 199912310101.01 "$WORK/src/a.jpg"
PATH=/usr/bin:/bin run -s "$WORK/src" --fallback mtime
have 'tgt/1999/12/1999-12-31 01.01.01.jpg'
grepout 'exiftool not found'

section "27. bad arguments are rejected"
t
run -s "$WORK/src" --dedupe wat; grepout '--dedupe must be'
run -s "$WORK/src" --hash none --dedupe skip; grepout 'needs duplicate detection'
"$SCRIPT" -t x >"$WORK/out.txt" 2>&1; grepout 'no source folder given'
"$SCRIPT" -s a -s b >"$WORK/out.txt" 2>&1; grepout 'cannot sort them all in place'
"$SCRIPT" --bogus >"$WORK/out.txt" 2>&1; grepout 'unknown option'

section "28. in-place: one folder, no --target"
t
mk src/loose/IMG_1.jpg '2018-11-30 22:10:00' one
mk src/loose/IMG_2.jpg '2019-01-02 03:04:05' two
mk 'src/2018/11/2018-11-30 22.11.00.jpg' '2018-11-30 22:11:00' three   # already right
"$SCRIPT" "$WORK/src" >"$WORK/out.txt" 2>&1
have 'src/2018/11/2018-11-30 22.10.00.jpg'
have 'src/2019/01/2019-01-02 03.04.05.jpg'
have 'src/2018/11/2018-11-30 22.11.00.jpg'
gone src/loose/IMG_1.jpg
count 3 src
grepout 'sorting .* in place'
grepout 'already in place     1'

section "28b. in-place via -s, dry run, and --prune-empty"
t
mk src/loose/IMG_1.jpg '2018-11-30 22:10:00' one
"$SCRIPT" -s "$WORK/src" -n >"$WORK/out.txt" 2>&1
have src/loose/IMG_1.jpg
grepout 'dry run'
"$SCRIPT" -s "$WORK/src" --prune-empty >"$WORK/out.txt" 2>&1
have 'src/2018/11/2018-11-30 22.10.00.jpg'
gone src/loose
have src            # the root itself must survive

section "28c. in-place is idempotent and refuses to copy"
t
mk src/a/x.jpg '2020-05-05 10:00:00' one
mk src/b/y.jpg '2020-05-05 10:00:00' two
"$SCRIPT" "$WORK/src" --prune-empty >"$WORK/out.txt" 2>&1
before=$(find "$WORK/src" -type f | sort)
"$SCRIPT" "$WORK/src" --copy >"$WORK/out.txt" 2>&1
after=$(find "$WORK/src" -type f | sort)
if [[ $before == "$after" ]]; then ok "in-place second run is a no-op"; else no "in-place run 2 changed things"; diff <(echo "$before") <(echo "$after"); fi
grepout 'makes no sense when sorting a folder in place'
count 2 src

section "28d. in-place dedupe of an existing folder"
t
mk src/a/x.jpg '2020-05-05 10:00:00' same
mk src/b/y.jpg '2020-05-05 10:00:00' same
"$SCRIPT" "$WORK/src" --dedupe delete --yes >"$WORK/out.txt" 2>&1
count 1 src
grepout 'duplicates deleted   1'

section "30. target cannot store unix permissions (exFAT/NTFS/SMB)"
FAILBIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/failbin
t
mk src/noperm-a.jpg '2021-07-15 14:23:11' a       # the stub refuses -p on these
mk src/noperm-b.jpg '2021-07-15 14:23:12' b
mk src/fine.jpg '2021-07-15 14:23:13' c
PATH="$FAILBIN/noperm:$PATH" run -s "$WORK/src" --copy
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.12.jpg'
have 'tgt/2021/07/2021-07-15 14.23.13.jpg'
count 3 tgt
count 3 src                                        # --copy leaves the originals
grepout 'copied               3'
grepout 'attributes not kept  2'
nogrepout 'FAILED'
nogrepout 'copy failed'
if [[ $(cat "$WORK/rc.txt") == 0 ]]; then ok "rc=0 despite the permission warnings"; else no "rc=$(cat "$WORK/rc.txt")"; fi
# the data must be complete, not truncated
if [[ $(sed -n 2p "$WORK/tgt/2021/07/2021-07-15 14.23.11.jpg") == a ]]; then ok "content intact"; else no "content damaged"; fi

section "30b. timestamps survive a permission-less target"
t
mk src/noperm.jpg -
touch -t 200502030405.06 "$WORK/src/noperm.jpg"
PATH="$FAILBIN/noperm:$PATH" run -s "$WORK/src" --copy --fallback mtime
have 'tgt/2005/02/2005-02-03 04.05.06.jpg'
if [[ $(date -r "$WORK/tgt/2005/02/2005-02-03 04.05.06.jpg" +%Y%m%d%H%M) == 200502030405 ]]; then ok "mtime preserved"; else no "mtime lost: $(date -r "$WORK/tgt/2005/02/2005-02-03 04.05.06.jpg" +%Y%m%d%H%M)"; fi

section "30c. --preserve timestamps avoids the failing attempt entirely"
t
mk src/noperm.jpg '2021-07-15 14:23:11'
PATH="$FAILBIN/noperm:$PATH" run -s "$WORK/src" --copy --preserve timestamps
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
grepout 'copied               1'
nogrepout 'attributes not kept'
nogrepout 'FAILED'

section "30d. cross-filesystem MOVE that cannot preserve permissions"
t
mk src/noperm-a.jpg '2021-07-15 14:23:11' a
mk src/fine.jpg '2021-07-15 14:23:12' b
PATH="$FAILBIN/noperm:$PATH" run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.12.jpg'
count 0 src                                        # move: originals gone
grepout 'moved                2'
grepout 'attributes not kept  1'
nogrepout 'FAILED'
if [[ $(sed -n 2p "$WORK/tgt/2021/07/2021-07-15 14.23.11.jpg") == a ]]; then ok "content intact"; else no "content damaged"; fi

section "30e. move where the data lands but the original cannot be removed"
t
mk src/keepsrc.jpg '2021-07-15 14:23:11' a
PATH="$FAILBIN/noperm:$PATH" run -s "$WORK/src"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
count 0 src            # verified byte-identical, so the original is cleaned up
grepout 'moved                1'
nogrepout 'FAILED'

section "31. transient failures are retried"
t
mk src/a.jpg '2021-07-15 14:23:11'
export FLAKY_DIR="$WORK/flaky" FLAKY_FAILS=2; mkdir -p "$FLAKY_DIR"
PATH="$FAILBIN/flaky:$PATH" run -s "$WORK/src" --copy --retries 3 -v
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
grepout 'succeeded on retry   1'
grepout 'retry 1/3'
nogrepout 'FAILED'

section "31b. --retries 0 does not retry"
t
mk src/a.jpg '2021-07-15 14:23:11'
export FLAKY_DIR="$WORK/flaky" FLAKY_FAILS=1; mkdir -p "$FLAKY_DIR"
PATH="$FAILBIN/flaky:$PATH" run -s "$WORK/src" --copy --retries 0
count 0 tgt
grepout 'FAILED               1'

section "32. permanent failures are listed with their paths"
t
mk src/a.jpg '2021-07-15 14:23:11'
mk src/b.jpg '2021-07-15 14:23:12'
export FLAKY_DIR="$WORK/flaky" FLAKY_FAILS=99; mkdir -p "$FLAKY_DIR"
PATH="$FAILBIN/flaky:$PATH" run -s "$WORK/src" --copy --retries 1 --log "$WORK/f.log"
count 0 tgt
count 2 src                                        # originals stay put
grepout 'FAILED               2'
grepout 'still not sorted after 1 retry'
grepout "$WORK/src/a.jpg"
grepout "$WORK/src/b.jpg"
grepout 'Input/output error'
if [[ $(cat "$WORK/rc.txt") == 1 ]]; then ok "rc=1 on failure"; else no "rc=$(cat "$WORK/rc.txt")"; fi
if grep -q 'failed' "$WORK/f.log"; then ok "failures recorded in the log"; else no "log has no failures"; fi
unset FLAKY_DIR FLAKY_FAILS

section "32b. no half-written file is left on the destination"
t
mk src/a.jpg '2021-07-15 14:23:11'
export FLAKY_DIR="$WORK/flaky" FLAKY_FAILS=99; mkdir -p "$FLAKY_DIR"
PATH="$FAILBIN/flaky:$PATH" run -s "$WORK/src" --copy --retries 0
gone 'tgt/2021/07/2021-07-15 14.23.11.jpg'
unset FLAKY_DIR FLAKY_FAILS

section "33. bad values for the new options"
t
run -s "$WORK/src" --preserve wat; grepout '--preserve must be'
run -s "$WORK/src" --retries x; grepout 'whole number'

section "29. exit code is 0 on success"
t
mk src/a.jpg '2021-07-15 14:23:11'
run -s "$WORK/src"
if [[ $(cat "$WORK/rc.txt") == 0 ]]; then ok "rc=0"; else no "rc=$(cat "$WORK/rc.txt")"; sed 's/^/       /' "$WORK/out.txt"; fi

printf '\n----------------------------------------\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$WORK"
((fail == 0))
