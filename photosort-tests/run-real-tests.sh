#!/usr/bin/env bash
# Tests sort-photos.sh against the REAL exiftool on files with REAL EXIF data.
set -uo pipefail

# override with: SCRIPT=/path/to/sort-photos.sh ./run-tests.sh
SCRIPT=${SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sort-photos.sh}
# use the system exiftool if there is one, else the local copy
[[ -d /root/.local/bin ]] && export PATH="/root/.local/bin:$PATH"
command -v exiftool >/dev/null || export PATH="$HOME/.local/bin:$PATH"
command -v exiftool >/dev/null || { echo "real exiftool not on PATH"; exit 1; }
echo "using exiftool $(exiftool -ver)"

WORK=$(mktemp -d /tmp/psreal.XXXXXX)
pass=0; fail=0
ok() { ((++pass)); printf '  ok   %s\n' "$1"; }
no() { ((++fail)); printf '  FAIL %s\n' "$1"; }
have() { if [[ -e "$WORK/$1" ]]; then ok "exists: $1"; else no "missing: $1"; find "$WORK" -type f | sed "s|$WORK|      .|"; fi; }
gone() { [[ -e "$WORK/$1" ]] && no "should not exist: $1" || ok "absent: $1"; }
count() { local n; n=$(find "$WORK/$2" -type f 2>/dev/null | wc -l); [[ $n == "$1" ]] && ok "$2 has $1 file(s)" || { no "$2 has $n, expected $1"; find "$WORK/$2" -type f | sed "s|$WORK|      .|"; }; }
grepout() { grep -qE -- "$1" "$WORK/out.txt" && ok "output matches /$1/" || { no "output lacks /$1/"; sed 's/^/       /' "$WORK/out.txt"; }; }
nogrepout() { grep -qE -- "$1" "$WORK/out.txt" && { no "output matches /$1/ unexpectedly"; sed 's/^/       /' "$WORK/out.txt"; } || ok "output free of /$1/"; }
run() { "$SCRIPT" "$@" >"$WORK/out.txt" 2>&1; }
section() { printf '\n== %s\n' "$1"; }

# a real 1x1 JPEG and a real 1x1 PNG
blank() { # blank <path> [png]
	mkdir -p "${1%/*}"
	if [[ ${2:-} == png ]]; then
		python3 -c "
import zlib,struct,sys
def c(t,d):
    b=t+d; return struct.pack('>I',len(d))+b+struct.pack('>I',zlib.crc32(b)&0xffffffff)
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+c(b'IDAT',zlib.compress(b'\x00\xff\x00\x00'))+c(b'IEND',b''))" "$1"
	else
		python3 -c "
import base64,sys
open(sys.argv[1],'wb').write(base64.b64decode('/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwcJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPDs0NDT/wAALCAABAAEBAREA/8QAFAABAQAAAAAAAAAAAAAAAAAAAAP/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAQAAAAAAAAAAAAAAAAAAAAP/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k='))" "$1"
	fi
}
tag() { # tag <path> <exiftool assignments...>
	local f=$1; shift
	exiftool -q -q -m -overwrite_original "$@" "$f" || no "could not tag $f"
}
fresh() { rm -rf "$WORK"/*; mkdir -p "$WORK/src" "$WORK/tgt"; }

# ---------------------------------------------------------------------------
section "R1. real EXIF DateTimeOriginal drives folder and name"
fresh
blank "$WORK/src/a.jpg"; tag "$WORK/src/a.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
blank "$WORK/src/b.JPG"; tag "$WORK/src/b.JPG" -DateTimeOriginal='2019:01:02 03:04:05'
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2019/01/2019-01-02 03.04.05.JPG'
grepout 'date from EXIF       2'
grepout 'date from filesystem 0'
nogrepout 'nothing usable'

section "R2. tag priority: DateTimeOriginal wins over CreateDate"
fresh
blank "$WORK/src/both.jpg"
tag "$WORK/src/both.jpg" -DateTimeOriginal='2022:02:02 02:02:02' -CreateDate='1999:11:11 11:11:11'
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2022/02/2022-02-02 02.02.02.jpg'
gone 'tgt/1999'

section "R3. CreateDate is used when DateTimeOriginal is absent"
fresh
blank "$WORK/src/c.jpg"; tag "$WORK/src/c.jpg" -CreateDate='2019:01:02 03:04:05'
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2019/01/2019-01-02 03.04.05.jpg'
grepout 'date from EXIF       1'

section "R4. no EXIF date at all -> filesystem date"
fresh
blank "$WORK/src/plain.jpg"; touch -t 200502030405.06 "$WORK/src/plain.jpg"
run -s "$WORK/src" -t "$WORK/tgt" --fallback mtime
have 'tgt/2005/02/2005-02-03 04.05.06.jpg'
grepout 'date from filesystem 1'

section "R5. mixed library: EXIF and non-EXIF files together"
fresh
blank "$WORK/src/withexif.jpg"; tag "$WORK/src/withexif.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
blank "$WORK/src/noexif.jpg"; touch -t 200502030405.06 "$WORK/src/noexif.jpg"
run -s "$WORK/src" -t "$WORK/tgt" --fallback mtime
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2005/02/2005-02-03 04.05.06.jpg'
grepout 'date from EXIF       1'
grepout 'date from filesystem 1'

section "R6. PNG container with EXIF"
fresh
blank "$WORK/src/shot.png" png; tag "$WORK/src/shot.png" -DateTimeOriginal='2024:04:04 04:04:04'
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2024/04/2024-04-04 04.04.04.png'
grepout 'date from EXIF       1'

section "R7. unicode, quotes and a TAB inside the file name"
fresh
blank "$WORK/src/Ünïcödé foto's.jpg"; tag "$WORK/src/Ünïcödé foto's.jpg" -DateTimeOriginal='2023:05:06 07:08:09'
blank "$WORK/src/with	tab.jpg"; tag "$WORK/src/with	tab.jpg" -DateTimeOriginal='2023:05:06 07:08:10'
blank "$WORK/src/dollar \$(rm -rf).jpg"; tag "$WORK/src/dollar \$(rm -rf).jpg" -DateTimeOriginal='2023:05:06 07:08:11'
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2023/05/2023-05-06 07.08.09.jpg'
have 'tgt/2023/05/2023-05-06 07.08.10.jpg'
have 'tgt/2023/05/2023-05-06 07.08.11.jpg'
grepout 'date from EXIF       3'
count 0 src

section "R8. real duplicates: same bytes, same EXIF"
fresh
blank "$WORK/src/orig.jpg"; tag "$WORK/src/orig.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
cp "$WORK/src/orig.jpg" "$WORK/src/copy.jpg"
run -s "$WORK/src" -t "$WORK/tgt" -n
grepout 'duplicates found     1'
run -s "$WORK/src" -t "$WORK/tgt" --dedupe delete --yes
count 1 tgt
count 0 src
grepout 'duplicates deleted   1'

section "R9. same EXIF second, different pixels -> (1)"
fresh
blank "$WORK/src/x1.jpg"; tag "$WORK/src/x1.jpg" -DateTimeOriginal='2020:05:05 10:00:00' -Artist=one
blank "$WORK/src/x2.jpg"; tag "$WORK/src/x2.jpg" -DateTimeOriginal='2020:05:05 10:00:00' -Artist=two
run -s "$WORK/src" -t "$WORK/tgt"
have 'tgt/2020/05/2020-05-05 10.00.00.jpg'
have 'tgt/2020/05/2020-05-05 10.00.00 (1).jpg'
grepout 'duplicates found     0'

section "R10. reorganising an existing library, then idempotent"
fresh
blank "$WORK/tgt/Urlaub/DSC_1.jpg"; tag "$WORK/tgt/Urlaub/DSC_1.jpg" -DateTimeOriginal='2019:07:01 09:15:00'
blank "$WORK/tgt/2019/07/2019-07-02 18.40.12.jpg"; tag "$WORK/tgt/2019/07/2019-07-02 18.40.12.jpg" -DateTimeOriginal='2019:07:02 18:40:12'
blank "$WORK/src/new.jpg"; tag "$WORK/src/new.jpg" -DateTimeOriginal='2021:12:24 20:00:00'
run -s "$WORK/src" -t "$WORK/tgt" --prune-empty
have 'tgt/2019/07/2019-07-01 09.15.00.jpg'
have 'tgt/2019/07/2019-07-02 18.40.12.jpg'
have 'tgt/2021/12/2021-12-24 20.00.00.jpg'
gone tgt/Urlaub
grepout 'already in place     1'
before=$(find "$WORK/tgt" -type f | sort)
run -s "$WORK/src" -t "$WORK/tgt"
after=$(find "$WORK/tgt" -type f | sort)
[[ $before == "$after" ]] && ok "second run is a no-op" || { no "second run changed the library"; diff <(echo "$before") <(echo "$after"); }
grepout 'already in place     3'

section "R11. in-place sorting of one folder"
fresh
blank "$WORK/src/loose/IMG_1.jpg"; tag "$WORK/src/loose/IMG_1.jpg" -DateTimeOriginal='2018:11:30 22:10:00'
blank "$WORK/src/loose/IMG_2.jpg"; tag "$WORK/src/loose/IMG_2.jpg" -DateTimeOriginal='2019:01:02 03:04:05'
run "$WORK/src" --prune-empty
have 'src/2018/11/2018-11-30 22.10.00.jpg'
have 'src/2019/01/2019-01-02 03.04.05.jpg'
gone src/loose
grepout 'sorting .* in place'
grepout 'date from EXIF       2'

section "R12. real .xmp sidecars follow the RAW file"
fresh
blank "$WORK/src/IMG_1.jpg"; tag "$WORK/src/IMG_1.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
printf '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>\n' >"$WORK/src/IMG_1.xmp"
run -s "$WORK/src" -t "$WORK/tgt" --sidecars
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.11.xmp'
count 0 src

section "R12b. darktable workflow: real EXIF + primary and duplicate sidecars"
fresh
blank "$WORK/src/IMG_7605.jpg"; tag "$WORK/src/IMG_7605.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
printf '<x:xmpmeta xmlns:x="adobe:ns:meta/"><!--main--></x:xmpmeta>\n' >"$WORK/src/IMG_7605.jpg.xmp"
printf '<x:xmpmeta xmlns:x="adobe:ns:meta/"><!--dup1--></x:xmpmeta>\n' >"$WORK/src/IMG_7605_01.jpg.xmp"
printf '<x:xmpmeta xmlns:x="adobe:ns:meta/"><!--dup2--></x:xmpmeta>\n' >"$WORK/src/IMG_7605_02.jpg.xmp"
run -s "$WORK/src" -t "$WORK/tgt" --log "$WORK/log.tsv"
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.11.jpg.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.jpg.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_02.jpg.xmp'
count 0 src
grepout 'sidecars             3'
grep -q dup2 "$WORK/tgt/2021/07/2021-07-15 14.23.11_02.jpg.xmp" && ok "dup2 edit intact" || no "dup2 edit lost"

section "R12c. reorganising a darktable library keeps photo and edits together"
fresh
blank "$WORK/tgt/messy/IMG_7605.jpg"; tag "$WORK/tgt/messy/IMG_7605.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
printf 'main\n' >"$WORK/tgt/messy/IMG_7605.jpg.xmp"
printf 'dup1\n' >"$WORK/tgt/messy/IMG_7605_01.jpg.xmp"
run "$WORK/tgt" --prune-empty
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.11.jpg.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.jpg.xmp'
gone tgt/messy
before=$(find "$WORK/tgt" -type f | sort)
run "$WORK/tgt"
[[ $before == "$(find "$WORK/tgt" -type f | sort)" ]] && ok "darktable library is stable on re-run" || no "re-run moved things"

section "R12d. real duplicate raws with different darktable edits"
fresh
blank "$WORK/src/IMG_7605.jpg"; tag "$WORK/src/IMG_7605.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
cp "$WORK/src/IMG_7605.jpg" "$WORK/src/IMG_7605_copy.jpg"          # byte-identical
printf '<x:xmpmeta><!--plus1EV--></x:xmpmeta>\n' >"$WORK/src/IMG_7605.jpg.xmp"
printf '<x:xmpmeta><!--blackandwhite--></x:xmpmeta>\n' >"$WORK/src/IMG_7605_copy.jpg.xmp"
run -s "$WORK/src" -t "$WORK/tgt" --dedupe delete --yes
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2021/07/2021-07-15 14.23.11.jpg.xmp'
have 'tgt/2021/07/2021-07-15 14.23.11_01.jpg.xmp'
count 3 tgt
count 0 src
grepout 'duplicates deleted   1'
grep -q blackandwhite "$WORK/tgt/2021/07/2021-07-15 14.23.11_01.jpg.xmp" && ok "differing edit preserved" || no "differing edit lost"
grep -q plus1EV "$WORK/tgt/2021/07/2021-07-15 14.23.11.jpg.xmp" && ok "surviving edit intact" || no "surviving edit damaged"
# and a second run must not shuffle any of it
before=$(find "$WORK/tgt" -type f | sort)
run -s "$WORK/src" -t "$WORK/tgt"
[[ $before == "$(find "$WORK/tgt" -type f | sort)" ]] && ok "stable on re-run" || no "re-run moved things"

section "R13. --fast (-fast2) still reads JPEG dates"
fresh
blank "$WORK/src/a.jpg"; tag "$WORK/src/a.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
run -s "$WORK/src" -t "$WORK/tgt" --fast
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
grepout 'date from EXIF       1'

section "R14. custom formats with real EXIF"
fresh
blank "$WORK/src/a.jpg"; tag "$WORK/src/a.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
run -s "$WORK/src" -t "$WORK/tgt" --dir-format '%Y/%Y-%m' --name-format 'IMG_%Y%m%d_%H%M%S' --lower-ext
have 'tgt/2021/2021-07/IMG_20210715_142311.jpg'

section "R15. a corrupt/truncated file does not derail the run"
fresh
blank "$WORK/src/good.jpg"; tag "$WORK/src/good.jpg" -DateTimeOriginal='2021:07:15 14:23:11'
head -c 40 "$WORK/src/good.jpg" >"$WORK/src/broken.jpg"; touch -t 201001010101.01 "$WORK/src/broken.jpg"
run -s "$WORK/src" -t "$WORK/tgt" --fallback mtime
have 'tgt/2021/07/2021-07-15 14.23.11.jpg'
have 'tgt/2010/01/2010-01-01 01.01.01.jpg'
grepout 'date from EXIF       1'

section "R16. 250 real JPEGs in one batch"
fresh
for i in $(seq 1 250); do blank "$WORK/src/f$i.jpg"; done
exiftool -q -q -m -overwrite_original -DateTimeOriginal='2020:06:15 12:00:00' "$WORK/src" >/dev/null 2>&1
run -s "$WORK/src" -t "$WORK/tgt"
count 250 tgt
grepout 'date from EXIF       250'
grepout 'date from filesystem 0'

printf '\n----------------------------------------\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$WORK"
((fail == 0))
