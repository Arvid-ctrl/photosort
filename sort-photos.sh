#!/usr/bin/env bash
#
# sort-photos.sh - sort photos/videos into YEAR/MONTH folders and name them
#                  after the date they were taken (EXIF), with safe conflict
#                  and duplicate handling.
#
# Requires: bash 4+, exiftool (recommended), GNU coreutils (stat/date/sort).
#           Without exiftool the script still works but falls back to
#           filesystem dates for every file.
#
set -Eeuo pipefail

VERSION=1.0

# ---------------------------------------------------------------- defaults ---
declare -a SOURCES=()
TARGET=""
DRY_RUN=0
DO_COPY=0                 # 0 = move, 1 = copy (target-tree files always move)
RENAME=1                  # 0 = keep original file names
NAME_FORMAT='%Y-%m-%d %H.%M.%S'
DIR_FORMAT='%Y/%m'
DEDUPE=keep               # keep | skip | delete
REORGANIZE=1              # also re-sort files already in the target
FALLBACK=birth            # birth | mtime | oldest | unsorted | skip
UNSORTED_DIR=Unsorted
HASH_MODE=sha256          # sha256 | quick | none
SIDECARS=1                # move .xmp & co. along with their photo
LOWER_EXT=0
PRUNE_EMPTY=0
FAST=0
PRESERVE=all              # all | timestamps | none
RETRIES=2                 # extra attempts per file after a failure
DUP_SIDECARS=reattach     # reattach | delete | keep
DEDUPE_SCOPE=name         # name | all
LOG_FILE=""
CACHE_FILE=""
ASSUME_YES=0
VERBOSE=0
QUIET=0

EXTS='jpg,jpeg,jpe,png,heic,heif,avif,tif,tiff,webp,gif,bmp,dng,cr2,cr3,nef,nrw,arw,srf,sr2,orf,rw2,raf,pef,srw,x3f,3fr,mp4,mov,m4v,avi,mts,m2ts,mkv,3gp,mpg,mpeg,wmv,webm'
ALL_FILES=0
SIDECAR_EXTS='xmp,aae,json,thm,lrv,pp3,dop,on1,arp'

# EXIF tags consulted, in priority order. Asking exiftool for the rare ones
# costs roughly twice as much per file, so the two that virtually every photo
# carries are read first and the rest only for whatever is still undated
# afterwards (videos, IPTC-only scans).
EXIF_TAGS=(DateTimeOriginal CreateDate)
EXIF_TAGS_RARE=(MediaCreateDate TrackCreateDate DateTimeCreated DigitalCreationDate GPSDateTime)

usage() {
	cat <<'EOF'
sort-photos.sh - sort photos into <year>/<month> folders, named by EXIF date.

USAGE
  sort-photos.sh -s SOURCE [-s SOURCE...] -t TARGET [options]
  sort-photos.sh SOURCE [options]        # sort that one folder in place

FOLDERS
  -s, --source DIR      Folder to take files from (repeatable). Can also be
                        given as a plain argument, without the -s.
  -t, --target DIR      Folder to sort into (created if missing). If you leave
                        it out, the single source folder is sorted IN PLACE:
                        its files are re-foldered and renamed where they are.
                        With more than one source a target is required.

WHAT HAPPENS
  Every file gets a date: EXIF DateTimeOriginal/CreateDate/... if present,
  otherwise the filesystem date (see --fallback). It is then placed at
      TARGET/<--dir-format>/<--name-format>.<original extension>
  Files already inside TARGET are re-sorted along with the new ones, so the
  whole library ends up consistent (disable with --no-reorganize).
  Name clashes get " (1)", " (2)", ... appended.

OPTIONS
  -n, --dry-run         Change nothing, just print the summary (-v for details).
      --copy            Copy from the sources instead of moving.
                        Files already in TARGET are always moved, never copied.
      --move            Move (default).
      --no-rename       Keep the original file names, only sort into folders.
      --name-format FMT strftime format for the file name.
                        Default: '%Y-%m-%d %H.%M.%S'
      --dir-format FMT  strftime format for the folder(s) below TARGET.
                        Default: '%Y/%m'   (e.g. '%Y/%Y-%m' or '%Y/%m %B')
      --dedupe MODE     What to do when a file is byte-identical to the file
                        already holding the wanted name:
                          keep   (default) put it next to it as "name (1)"
                          skip   leave it where it is, touch nothing
                          delete delete the duplicate
                        Only files that end up competing for the same name are
                        compared. Two copies of one photo named .jpg and .JPG
                        do not collide, so add --lower-ext to catch those.
      --dedupe-scope S  Which files are compared with each other:
                          name (default) only files that end up wanting the
                               same name. Copies keep their EXIF date, so
                               IMG_3024.CR2 and IMG_3024(1).CR2 do land on the
                               same name and ARE found - but .CR2 vs .cr2,
                               .jpg vs .jpeg or --no-rename are not
                          all  compare every file by content, whatever it is
                               called. Groups by size first, so only real
                               candidates get hashed
      --dup-sidecars M  What happens to the sidecars of a duplicate that
                        --dedupe delete removes (their edits may differ from
                        the surviving photo's, so they are not just junk):
                          reattach (default) an identical edit is deleted with
                                   the photo; a different one is kept as
                                   another darktable version of the survivor
                                   (..._01.CR2.xmp), so no edit is ever lost
                          delete   remove them together with the duplicate
                          keep     leave them where they are (orphaned)
      --no-reorganize   Leave files that are already in TARGET alone.
      --fallback MODE   Used when a file has no usable EXIF date:
                          birth  (default) creation/birth time, else mtime
                          mtime  modification time
                          oldest the earlier of the two - usually the best
                                 guess, because copying a photo onto a disk
                                 gives it a brand new birth time while
                                 keeping the old mtime
                          unsorted  move to TARGET/Unsorted, keep the name
                          skip   leave the file alone
      --unsorted-dir N  Name of that folder (default: Unsorted).
      --ext LIST        Comma-separated extensions to process. Default:
                        common image, RAW and video types.
      --all-files       Process every file regardless of extension.
      --hash MODE       Duplicate detection: sha256 (default), quick
                        (size, then byte compare), none (disables it).
      --no-sidecars     Do NOT move editor sidecars along with their photo.
                        By default IMG_7605.CR2.xmp, IMG_7605.xmp and every
                        darktable duplicate (IMG_7605_01.CR2.xmp, _02, ...)
                        follow the photo and are renamed to match it, so the
                        edits stay attached. Recognised: xmp aae json thm lrv
                        pp3 dop on1 arp.
      --lower-ext       Normalise extensions to lower case (.JPG -> .jpg).
      --prune-empty     Delete directories that are left empty, in the sources
                        and (while reorganising) in the target as well.
      --fast            Pass -fast2 to exiftool, which skips the scan for
                        trailing metadata. Measured effect on ordinary photos:
                        none - exiftool already stops after the header, so a
                        40 MB raw costs the same as a 200 byte JPEG. Can help on
                        odd files with metadata trailers; may miss dates in
                        video containers, so only reach for it if a run is slow
                        and the timings point at the date-reading phase.
      --preserve MODE   How hard to try to keep file attributes when copying:
                          all        (default) mode, owner and timestamps; if
                                     the target cannot store them the file is
                                     still copied and only counted as
                                     "attributes not preserved"
                          timestamps skip mode/owner, keep the times. Use this
                                     for exFAT/NTFS/SMB targets to avoid the
                                     pointless first attempt per file
                          none       copy the data only
      --retries N       Retry a failed move/copy N more times, waiting 1s, 2s,
                        4s, ... in between (default 2, 0 disables). Paths that
                        still fail are listed at the end of the summary.
      --log FILE        Append a TSV log of every operation (undo-able).
      --cache FILE      Remember each file's EXIF date in FILE (path, size,
                        mtime, date) and reuse it while size and mtime stay
                        unchanged. Reading EXIF is the slow part of a run, about
                        3 seconds per thousand photos, so a second pass over a
                        big library costs almost nothing. Any change to a file
                        simply misses the cache and is read again.
  -y, --yes             Do not ask for confirmation before deleting.
  -v, --verbose         Print every planned/performed operation.
  -q, --quiet           Only print the summary and errors.
  -h, --help            This text.
      --version         Print the version.

SPEED ON A BIG LIBRARY
  Reading EXIF is the whole cost of a run: exiftool must open every file, about
  4 seconds per thousand photos. The tree walk itself is nothing. So:

  # Adding photos to a big library: only the new files are looked at. Existing
  # names are checked on disk one at a time, as each name is needed.
  sort-photos.sh -s ~/Import -t ~/Pictures --no-reorganize      # 10k library: 0.2s

  # Re-tidying the whole library: let it remember the dates it read.
  sort-photos.sh ~/Pictures --cache ~/.photo-dates.tsv          # 2nd run: ~3s vs ~50s

  What --no-reorganize gives up: files already in the library are not re-sorted,
  --dedupe-scope all cannot see the library's contents (so duplicate detection
  falls back to files competing for the same name), and the dry-run summary only
  covers the incoming files. Nothing is at risk - just less is looked at.

EXAMPLES
  # See what would happen, without touching anything:
  sort-photos.sh -s ~/Import -t ~/Pictures -n -v

  # Tidy up one existing folder in place (dry run first!):
  sort-photos.sh ~/Pictures -n -v
  sort-photos.sh ~/Pictures --prune-empty

  # Normal run: move everything, dedupe by deleting exact duplicates:
  sort-photos.sh -s ~/Import -t ~/Pictures --dedupe delete --log ~/sort.log

  # Only sort into folders, keep file names, copy instead of move:
  sort-photos.sh -s /mnt/card -t ~/Pictures --copy --no-rename

UNDO (when --log was used)
  tac sort.log | awk -F'\t' '$2=="move"||$2=="reorganize"{print $4"\t"$3}' \
    | while IFS=$'\t' read -r a b; do mkdir -p "$(dirname "$b")"; mv -n -- "$a" "$b"; done
EOF
}

# Wall-clock helpers. EPOCHREALTIME follows the locale, so a German system
# hands back "1756897.123456" with a comma - normalise it before doing maths.
now_ms() {
	if [[ -n ${EPOCHREALTIME:-} ]]; then
		local t=${EPOCHREALTIME/,/.}
		printf '%s' "$(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))"
	else printf '%s' "$((SECONDS * 1000))"; fi
}
took() { # <start ms> <label> [item count]
	local ms=$(( $(now_ms) - $1 )) rate=''
	if [[ -n ${3:-} ]] && (($3 > 0)) && ((ms > 0)); then
		rate=", $(( $3 * 1000 / ms )) files/s"
	fi
	info "  [$2: $((ms / 1000)).$(printf '%03d' $((ms % 1000)))s$rate]"
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { ((QUIET)) || printf '%s\n' "$*"; }
chat() { ((VERBOSE)) && printf '%s\n' "$*"; return 0; }

# ------------------------------------------------------------ argv parsing ---
while (($#)); do
	case $1 in
	-s | --source) SOURCES+=("${2:?--source needs a directory}"); shift 2 ;;
	-t | --target) TARGET=${2:?--target needs a directory}; shift 2 ;;
	-n | --dry-run) DRY_RUN=1; shift ;;
	--copy) DO_COPY=1; shift ;;
	--move) DO_COPY=0; shift ;;
	--no-rename) RENAME=0; shift ;;
	--name-format) NAME_FORMAT=${2:?}; shift 2 ;;
	--dir-format) DIR_FORMAT=${2:?}; shift 2 ;;
	--dedupe) DEDUPE=${2:?}; shift 2 ;;
	--dup-sidecars) DUP_SIDECARS=${2:?}; shift 2 ;;
	--dedupe-scope) DEDUPE_SCOPE=${2:?}; shift 2 ;;
	--no-reorganize | --no-reorganise) REORGANIZE=0; shift ;;
	--fallback) FALLBACK=${2:?}; shift 2 ;;
	--unsorted-dir) UNSORTED_DIR=${2:?}; shift 2 ;;
	--ext) EXTS=${2:?}; shift 2 ;;
	--all-files) ALL_FILES=1; shift ;;
	--hash) HASH_MODE=${2:?}; shift 2 ;;
	--sidecars) SIDECARS=1; shift ;;
	--no-sidecars) SIDECARS=0; shift ;;
	--lower-ext) LOWER_EXT=1; shift ;;
	--prune-empty) PRUNE_EMPTY=1; shift ;;
	--fast) FAST=1; shift ;;
	--preserve) PRESERVE=${2:?}; shift 2 ;;
	--retries) RETRIES=${2:?}; shift 2 ;;
	--log) LOG_FILE=${2:?}; shift 2 ;;
	--cache) CACHE_FILE=${2:?}; shift 2 ;;
	-y | --yes) ASSUME_YES=1; shift ;;
	-v | --verbose) VERBOSE=1; shift ;;
	-q | --quiet) QUIET=1; shift ;;
	-h | --help) usage; exit 0 ;;
	--version) printf 'sort-photos.sh %s\n' "$VERSION"; exit 0 ;;
	--) shift; break ;;
	-?*) die "unknown option: $1 (try --help)" ;;
	*) SOURCES+=("$1"); shift ;;     # a plain path is a source
	esac
done
(($#)) && SOURCES+=("$@")           # anything after --

((${#SOURCES[@]})) || die "no source folder given (try --help)"

# No target? Then sort the one source folder in place.
IN_PLACE=0
if [[ -z $TARGET ]]; then
	((${#SOURCES[@]} == 1)) || die "several sources but no --target: cannot sort them all in place"
	TARGET=${SOURCES[0]}
	IN_PLACE=1
fi
case $DEDUPE in keep | skip | delete) ;; *) die "--dedupe must be keep, skip or delete" ;; esac
case $DEDUPE_SCOPE in name | all) ;; *) die "--dedupe-scope must be name or all" ;; esac
[[ $DEDUPE_SCOPE == all && $HASH_MODE == none ]] && die "--dedupe-scope all needs hashing (--hash sha256)"
case $DUP_SIDECARS in reattach | delete | keep) ;; *) die "--dup-sidecars must be reattach, delete or keep" ;; esac
case $FALLBACK in birth | mtime | oldest | unsorted | skip) ;; *) die "--fallback must be birth, mtime, oldest, unsorted or skip" ;; esac
case $HASH_MODE in sha256 | quick | none) ;; *) die "--hash must be sha256, quick or none" ;; esac
case $PRESERVE in all | timestamps | none) ;; *) die "--preserve must be all, timestamps or none" ;; esac
[[ $RETRIES =~ ^[0-9]+$ ]] || die "--retries needs a whole number, got: $RETRIES"
[[ $HASH_MODE == none && $DEDUPE != keep ]] && die "--dedupe $DEDUPE needs duplicate detection (--hash sha256|quick)"

if ((IN_PLACE)) && ((DO_COPY)); then
	warn "--copy makes no sense when sorting a folder in place - moving instead"
	DO_COPY=0
fi
if ((IN_PLACE)) && ((!REORGANIZE)); then
	warn "--no-reorganize has no effect when sorting a folder in place"
fi

if ((DO_COPY)) && [[ $DEDUPE == delete ]]; then
	warn "--copy never deletes anything in the sources; duplicates found there are skipped instead"
fi

for s in "${SOURCES[@]}"; do [[ -d $s ]] || die "source is not a directory: $s"; done
if [[ ! -d $TARGET ]]; then
	((DRY_RUN)) || mkdir -p -- "$TARGET" || die "cannot create target: $TARGET"
fi

abspath() { # normalise without requiring existence
	if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"; else
		local d=${1%/*} b=${1##*/}
		[[ $d == "$1" ]] && d=.
		printf '%s/%s\n' "$(cd -- "$d" 2>/dev/null && pwd || printf '%s' "$d")" "$b"
	fi
}
TARGET=$(abspath "$TARGET")
LOG_ABS=''; [[ -n $LOG_FILE ]] && LOG_ABS=$(abspath "$LOG_FILE")
CACHE_ABS=''; [[ -n $CACHE_FILE ]] && CACHE_ABS=$(abspath "$CACHE_FILE")
for i in "${!SOURCES[@]}"; do SOURCES[i]=$(abspath "${SOURCES[i]}"); done

# ------------------------------------------------------- platform plumbing ---
HAVE_EXIFTOOL=0
command -v exiftool >/dev/null 2>&1 && HAVE_EXIFTOOL=1
((HAVE_EXIFTOOL)) || warn "exiftool not found - falling back to filesystem dates for every file"

DATE_BSD=0
date -d @0 +%Y >/dev/null 2>&1 || DATE_BSD=1
STAT_BSD=0
stat -c %Y . >/dev/null 2>&1 || STAT_BSD=1
SORT_Z=1
printf 'a\0' | sort -z >/dev/null 2>&1 || SORT_Z=0
CP_PRESERVE_TS=1          # BSD/macOS cp has no --preserve=
cp --preserve=timestamps --help >/dev/null 2>&1 || CP_PRESERVE_TS=0

# canonical internal date representation: "YYYY-MM-DD HH:MM:SS"
fmt_date() { # <canonical date> <strftime format>  -> formatted
	if ((DATE_BSD)); then date -j -f '%Y-%m-%d %H:%M:%S' "$1" +"$2"; else date -d "$1" +"$2"; fi
}
epoch_to_canonical() {
	if ((DATE_BSD)); then date -r "$1" +'%Y-%m-%d %H:%M:%S'; else date -d "@$1" +'%Y-%m-%d %H:%M:%S'; fi
}
stat_field() { # <file> <birth|mtime|size>
	if ((STAT_BSD)); then
		case $2 in birth) stat -f %B -- "$1" ;; mtime) stat -f %m -- "$1" ;; size) stat -f %z -- "$1" ;; esac
	else
		case $2 in birth) stat -c %W -- "$1" ;; mtime) stat -c %Y -- "$1" ;; size) stat -c %s -- "$1" ;; esac
	fi
}

TMPDIR_=$(mktemp -d "${TMPDIR:-/tmp}/sort-photos.XXXXXX")
STAGE="$TARGET/.sort-photos-staging-$$"
cleanup() {
	rm -rf -- "$TMPDIR_"
	if [[ -d $STAGE ]] && ! rmdir -- "$STAGE" 2>/dev/null; then
		warn "files were left behind in $STAGE - please move them back manually"
	fi
	return 0
}
trap cleanup EXIT

# ----------------------------------------------------------------- collect ---
declare -a files=() origins=()          # origins: "src" or "tgt"
declare -A in_moveset=()                # every path we are going to touch
declare -A date_of=() date_src=() hash_of=()
declare -A f_size=() f_mtime=() f_btime=()
# "<dir>|<stem>" -> the sidecar file names belonging to that stem, \x01 separated.
# Built once while walking, so finding a photo's sidecars is a hash lookup. It
# used to be three shell globs per photo, and a glob has to read the whole
# directory - in a folder with 5000 photos that is 75 million comparisons.
declare -A side_of=()

index_sidecar() { # <dir> <name>
	local dir=$1 nm=$2 base=${2%.*} key
	while :; do
		key="$dir|$base"
		side_of[$key]="${side_of[$key]:-}"$'\x01'"$nm"
		# a darktable duplicate edit (IMG_7605_01.CR2.xmp) belongs to IMG_7605 too
		if [[ $base =~ ^(.+)_[0-9]+$ ]]; then
			key="$dir|${BASH_REMATCH[1]}"
			side_of[$key]="${side_of[$key]:-}"$'\x01'"$nm"
		fi
		[[ $base == *.* ]] || break
		base=${base%.*}
	done
	return 0
}

sidecar_candidates() { # <dir> <stem> -> SC_LIST
	SC_LIST=()
	local list=${side_of["$1|$2"]:-}
	[[ -n $list ]] || return 0
	local -a parts=()
	IFS=$'\x01' read -r -a parts <<<"$list"
	local nm
	for nm in "${parts[@]}"; do [[ -n $nm ]] && SC_LIST+=("$1/$nm"); done
	return 0
}

want_ext() { # <lowercase extension without dot>
	((ALL_FILES)) && return 0
	[[ -z $1 ]] && return 1
	case ",$EXTS," in *",$1,"*) return 0 ;; esac
	return 1
}
split_name() { # <path> -> SN_DIR SN_STEM SN_EXT (SN_EXT includes the dot)
	SN_DIR=${1%/*}; local n=${1##*/}
	if [[ $n == *.* && ${n%.*} != "" ]]; then SN_STEM=${n%.*}; SN_EXT=".${n##*.}"; else SN_STEM=$n; SN_EXT=""; fi
}

# find already walks every inode, so it can hand over size, mtime and birth time
# on the way past for free. That saves one stat(1) fork per file later on, which
# on a 40k library is minutes rather than milliseconds.
FIND_FMT='%p\t%s\t%Ts\t%Bs\0'
FIND_STATS=1
find /dev/null -maxdepth 0 -printf "$FIND_FMT" >/dev/null 2>&1 || FIND_STATS=0

collect() { # <root> <origin>
	local root=$1 origin=$2 f n ext rec rest
	while IFS= read -r -d '' rec; do
		if ((FIND_STATS)); then
			# parse from the right: a path may itself contain tabs
			f=$rec
			b=${f##*$'\t'}; rest=${f%$'\t'*}
			m=${rest##*$'\t'}; rest=${rest%$'\t'*}
			s=${rest##*$'\t'}; f=${rest%$'\t'*}
		else
			f=$rec; s=''; m=''; b=''
		fi
		[[ $f == "$STAGE"/* ]] && continue
		[[ -n $LOG_FILE && $f == "$LOG_ABS" ]] && continue
		[[ -n $CACHE_FILE && $f == "$CACHE_ABS" ]] && continue
		[[ -n ${in_moveset[$f]:-} ]] && continue      # source inside target etc.
		n=${f##*/}
		[[ $n == .* ]] && ((!ALL_FILES)) && continue  # skip .DS_Store & friends
		ext=${n##*.}; [[ $ext == "$n" ]] && ext=""
		case ",$SIDECAR_EXTS," in *",${ext,,},"*) index_sidecar "${f%/*}" "$n" ;; esac
		want_ext "${ext,,}" || continue
		files+=("$f"); origins+=("$origin"); in_moveset[$f]=1
		[[ -n $s ]] && f_size[$f]=$s
		[[ $m =~ ^[0-9]+$ ]] && f_mtime[$f]=$m
		[[ $b =~ ^[0-9]+$ ]] && f_btime[$f]=$b
		((${#files[@]} % 5000 == 0)) && info "  ... ${#files[@]} files so far"
	done < <(if ((FIND_STATS)); then
			find "$root" -type f -printf "$FIND_FMT" 2>/dev/null
		else find "$root" -type f -print0 2>/dev/null; fi |
		if ((SORT_Z)); then LC_ALL=C sort -z; else cat; fi)
	return 0
}

((IN_PLACE)) && info "sorting $TARGET in place"
T_SCAN=$(now_ms)

# Target tree first: files already in place get first claim on their own name.
((REORGANIZE)) && [[ -d $TARGET ]] && collect "$TARGET" tgt
for s in "${SOURCES[@]}"; do collect "$s" src; done

((${#files[@]})) || { info "nothing to do - no matching files found."; exit 0; }
info "scanning ${#files[@]} file(s)..."
took "$T_SCAN" "walking the folders" "${#files[@]}"

# ------------------------------------------------------------ read the dates ---
valid_date() { [[ $1 == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9] && $1 != 0000-* ]]; }

# An EXIF read is by far the slowest part of a run: exiftool has to open every
# single file. Size and mtime identify a photo well enough to reuse last run's
# answer, which makes a second pass over an unchanged library almost free.
declare -A cache_date=() cache_size=() cache_mtime=()
load_cache() {
	[[ -n $CACHE_FILE && -r $CACHE_FILE ]] || return 0
	local rec d m sz path n=0
	while IFS= read -r rec; do
		[[ $rec == '#'* || -z $rec ]] && continue
		d=${rec##*$'\t'}; rec=${rec%$'\t'*}
		m=${rec##*$'\t'}; rec=${rec%$'\t'*}
		sz=${rec##*$'\t'}; path=${rec%$'\t'*}
		[[ -n $path && -n $d ]] || continue
		cache_date[$path]=$d; cache_size[$path]=$sz; cache_mtime[$path]=$m; ((++n))
	done <"$CACHE_FILE"
	((n)) && info "  reusing $n cached date(s) from $CACHE_FILE"
	return 0
}

write_cache() {
	[[ -n $CACHE_FILE ]] || return 0
	((DRY_RUN)) && return 0
	local tmp=$TMPDIR_/cache.new i src dst p
	local -A out=()
	# keep what we already knew about files that are still there
	for p in "${!cache_date[@]}"; do
		[[ -e $p ]] && out[$p]="${cache_size[$p]}"$'\t'"${cache_mtime[$p]}"$'\t'"${cache_date[$p]}"
	done
	# and record this run's findings under the paths the files ended up at.
	# mv/cp -p keep size and mtime, so the source's values describe the copy.
	for i in "${!p_src[@]}"; do
		src=${p_src[i]}; dst=${p_dst[i]}
		case ${p_act[i]} in place | inplace) ;; *) continue ;; esac
		[[ -n $dst && -n ${date_of[$src]:-} && -e $dst ]] || continue
		out[$dst]="${f_size[$src]:-}"$'\t'"${f_mtime[$src]:-}"$'\t'"${date_of[$src]}"
	done
	{ printf '#path\tsize\tmtime\tdate\n'
	  for p in "${!out[@]}"; do printf '%s\t%s\n' "$p" "${out[$p]}"; done
	} >"$tmp" && mv -- "$tmp" "$CACHE_FILE" || warn "could not write the cache: $CACHE_FILE"
	return 0
}

# One batched exiftool call for a list of files and a set of tags.
# Sets EP_PARSED to the number of lines that came back in the expected shape.
exif_pass() { # <listfile> <tag>...
	local list=$1; shift
	local -a tags=("$@")
	local fmt='' t line path v n=${#tags[@]}
	local -a fields
	EP_PARSED=0
	# NOTE: exiftool does NOT expand "\t" in a -p format given on the command
	# line, it prints those two characters literally. The separator has to be a
	# real tab, otherwise nothing below can be split apart.
	for t in "${tags[@]}"; do fmt+="\${$t}"$'\t'; done
	fmt+='$FilePath'
	local -a cmd=(exiftool -m -q -q -f -charset filename=utf8 -d '%Y-%m-%d %H:%M:%S' -p "$fmt")
	((FAST)) && cmd+=(-fast2)
	cmd+=(-@ "$list")
	while IFS= read -r line; do
		IFS=$'\t' read -r -a fields <<<"$line"
		((${#fields[@]} > n)) || continue      # unexpected output - ignore the line
		# the path is everything from field N on (paths may contain tabs)
		path=$(IFS=$'\t'; printf '%s' "${fields[*]:n}")
		[[ -n $path && -n ${in_moveset[$path]:-} ]] || continue
		((++EP_PARSED))
		for v in "${fields[@]:0:n}"; do
			if valid_date "$v"; then date_of[$path]=$v; date_src[$path]=exif; break; fi
		done
	done < <("${cmd[@]}" 2>/dev/null || true)
	return 0
}

read_exif_dates() {
	((HAVE_EXIFTOOL)) || return 0
	local list=$TMPDIR_/files.txt rare=$TMPDIR_/rare.txt f hits=0 todo rest=0
	: >"$list"
	for f in "${files[@]}"; do
		if [[ -n ${cache_date[$f]:-} ]] &&
			[[ ${cache_size[$f]} == "${f_size[$f]:-}" && ${cache_mtime[$f]} == "${f_mtime[$f]:-}" ]]; then
			date_of[$f]=${cache_date[$f]}; date_src[$f]=cache; ((++hits)); continue
		fi
		printf '%s\n' "$f" >>"$list"
	done
	todo=$((${#files[@]} - hits))
	((hits)) && info "  $hits file(s) unchanged since the last run - skipping their EXIF"
	((todo)) || return 0

	info "  reading EXIF from $todo file(s)..."
	exif_pass "$list" "${EXIF_TAGS[@]}"
	# Not one line came back in the expected shape: rather than silently dating
	# the whole library from the filesystem, say so.
	((EP_PARSED)) || { warn "exiftool returned nothing usable - falling back to filesystem dates for every file"; return 0; }

	: >"$rare"
	while IFS= read -r f; do
		[[ -n ${date_of[$f]:-} ]] || { printf '%s\n' "$f" >>"$rare"; ((++rest)); }
	done <"$list"
	if ((rest)); then
		info "  $rest file(s) had no everyday date tag - checking the rarer ones..."
		exif_pass "$rare" "${EXIF_TAGS_RARE[@]}"
	fi
	return 0
}

fs_date() { # <file> -> canonical date, or empty
	local b="" m=""
	if [[ $FALLBACK == birth || $FALLBACK == oldest ]]; then
		b=${f_btime[$1]:-}
		[[ -z $b ]] && b=$(stat_field "$1" birth 2>/dev/null || true)
		[[ $b =~ ^[0-9]+$ ]] && ((b > 0)) || b=""
	fi
	if [[ -z $b || $FALLBACK == oldest ]]; then
		m=${f_mtime[$1]:-}
		[[ -z $m ]] && m=$(stat_field "$1" mtime 2>/dev/null || true)
		[[ $m =~ ^[0-9]+$ ]] || m=""
	fi
	local e=${b:-$m}
	# "oldest": a photo copied from a camera keeps its old mtime but gets a
	# brand new birth time, so the earlier of the two is the better guess.
	[[ -n $b && -n $m ]] && ((m < b)) && e=$m
	[[ -n $e ]] || return 1
	# "@<epoch>" is understood by the batch formatter below, and costs no fork
	printf '@%s' "$e"
}

# EXIF timestamps are bare wall-clock readings with no timezone, so they are
# reformatted under TZ=UTC0: the digits come back out exactly as they went in,
# and times that do not exist in the local zone (02:30 on a spring-forward
# Sunday) no longer fail. Filesystem timestamps are real instants and keep being
# rendered in local time. UTC0 is the POSIX spelling - it needs no zoneinfo.
# One date(1) invocation for every distinct timestamp in the whole run. Each
# output line repeats its own input as the first field, so lines can never be
# mis-assigned even if date(1) rejects one of them.
format_dates() { # fills fmt_dir[] / fmt_name[]
	local i k sep=$'\x01' stamps=$TMPDIR_/stamps.txt epochs=$TMPDIR_/epochs.txt
	local -A want_s=() want_e=()
	for i in "${!files[@]}"; do
		[[ ${c_state[i]} == ok ]] || continue
		k=${c_date[i]}
		if [[ $k == @* ]]; then want_e[${k#@}]=1; else want_s[$k]=1; fi
	done
	if ((DATE_BSD)); then      # BSD date cannot read a list, so keep it simple
		local out
		for k in "${!want_s[@]}"; do
			out=$(TZ=UTC0 fmt_date "$k" "$DIR_FORMAT$sep$NAME_FORMAT" 2>/dev/null) || continue
			fmt_dir[$k]=${out%%"$sep"*}; fmt_name[$k]=${out#*"$sep"}
		done
		for k in "${!want_e[@]}"; do
			out=$(date -r "$k" +"$DIR_FORMAT$sep$NAME_FORMAT" 2>/dev/null) || continue
			fmt_dir[$k]=${out%%"$sep"*}; fmt_name[$k]=${out#*"$sep"}
		done
		return 0
	fi
	local key dir name
	if ((${#want_s[@]})); then
		printf '%s\n' "${!want_s[@]}" >"$stamps"
		while IFS=$sep read -r key dir name; do
			[[ -n $key ]] && { fmt_dir[$key]=$dir; fmt_name[$key]=$name; }
		done < <(TZ=UTC0 date -f "$stamps" +"%Y-%m-%d %H:%M:%S$sep$DIR_FORMAT$sep$NAME_FORMAT" 2>/dev/null || true)
	fi
	if ((${#want_e[@]})); then
		printf '@%s\n' "${!want_e[@]}" >"$epochs"
		while IFS=$sep read -r key dir name; do
			[[ -n $key ]] && { fmt_dir[$key]=$dir; fmt_name[$key]=$name; }
		done < <(date -f "$epochs" +"%s$sep$DIR_FORMAT$sep$NAME_FORMAT" 2>/dev/null || true)
	fi
	return 0
}

# ---------------------------------------------------------- hashing / dupes ---
file_size() {
	[[ -n ${f_size[$1]:-} ]] && { printf '%s' "${f_size[$1]}"; return; }
	if [[ -f $1 ]]; then stat_field "$1" size 2>/dev/null || echo -1; else echo -1; fi
}
same_size() { local a; a=$(file_size "$1"); [[ $a != -1 && $a == "$(file_size "$2")" ]]; }
# Used before deleting an original: size alone is not enough of a promise.
content_matches() {
	same_size "$1" "$2" || return 1
	[[ $HASH_MODE == none ]] && return 0
	local a
	file_hash "$1"; a=$FH
	file_hash "$2"
	[[ $a == "$FH" ]]
}

# Decided once, not per file.
SHA_CMD=(sha256sum)
command -v sha256sum >/dev/null 2>&1 || SHA_CMD=(shasum -a 256)

# Hands the digest back in the global FH rather than on stdout. Printing it would
# force the caller into $( ), and a command substitution is a subshell - so every
# assignment to hash_of[] was thrown away and each comparison re-read the file
# from disk. With a name-clash chain that turns into O(files squared) hashing.
FH=''
file_hash() { # <path> -> FH
	if [[ -n ${hash_of[$1]:-} ]]; then FH=${hash_of[$1]}; return 0; fi
	local h
	read -r h _ < <("${SHA_CMD[@]}" -- "$1")
	hash_of[$1]=$h; FH=$h
	return 0
}
same_content() {
	[[ $1 == "$2" ]] && return 0
	case $HASH_MODE in
	none) return 1 ;;
	quick) [[ $(file_size "$1") == "$(file_size "$2")" ]] && cmp -s -- "$1" "$2" ;;
	*)
		local a
		file_hash "$1"; a=$FH
		file_hash "$2"
		[[ $a == "$FH" ]] ;;
	esac
}

# ------------------------------------------------------------ plan the moves ---
declare -a p_src=() p_dst=() p_act=() p_move=() p_org=()
CUR_ORIGIN=src            # origin of the file currently being planned
declare -A claimed=()      # destination path -> source path that claims it
declare -A plan_of=()      # source path -> plan index
n_exif=0 n_fs=0 n_nodate=0 n_dups=0 n_err=0

# Find a free destination. Sets RD_DEST and RD_ACT (place|inplace|dup|error).
resolve_dest() { # <src> <dir> <base> <ext> <dedupe_allowed>
	local src=$1 dir=$2 base=$3 ext=$4 allow=$5
	local i=0 cand other counted=0
	while :; do
		if ((i == 0)); then cand="$dir/$base$ext"; else cand="$dir/$base ($i)$ext"; fi
		other=""
		if [[ $cand == "$src" ]]; then
			claimed[$cand]=$src; RD_DEST=$cand; RD_ACT=inplace; return
		elif [[ -n ${claimed[$cand]:-} ]]; then
			other=${claimed[$cand]}
		elif [[ -e $cand ]]; then
			if [[ -n ${in_moveset[$cand]:-} ]]; then
				# occupied by a file that is itself moving away - free for us,
				# the execution phase moves the blocker out of the way first.
				claimed[$cand]=$src; RD_DEST=$cand; RD_ACT=place; return
			fi
			other=$cand
		fi
		if [[ -z $other ]]; then
			claimed[$cand]=$src; RD_DEST=$cand; RD_ACT=place; return
		fi
		if ((allow)) && [[ $HASH_MODE != none ]] && same_content "$src" "$other"; then
			((counted)) || { ((++n_dups)); counted=1; }
			# RD_KEEP is where the copy we are keeping ends up - the duplicate's
			# sidecars have to be dealt with relative to that, not to $other,
			# which is only the twin's current location.
			if [[ $DEDUPE != keep ]]; then RD_DEST=$other; RD_KEEP=$cand; RD_ACT=dup; return; fi
		fi
		if ((++i > 9999)); then RD_ACT=error; RD_DEST=""; return; fi
	done
}

add_plan() { # <src> <dst> <act> <move?>
	local idx=${#p_src[@]}
	p_src+=("$1"); p_dst+=("$2"); p_act+=("$3"); p_move+=("$4"); p_org+=("$CUR_ORIGIN")
	plan_of[$1]=$idx
}

plan_sidecars() { # <main src> <main dst> <main ext> <move?> [keep original names]
	((SIDECARS)) || return 0
	split_name "$1"; local sdir=$SN_DIR sstem=$SN_STEM
	local ddir=${2%/*} dname=${2##*/} keep=${5:-0}
	local dbase=${dname%"$3"} e sc suf mid owner
	local -A seen=()
	# darktable writes IMG_7605.CR2.xmp for the raw itself and IMG_7605_01.CR2.xmp,
	# IMG_7605_02.CR2.xmp, ... for every duplicate edit of it. Lightroom and
	# friends write IMG_7605.xmp. All of those have to travel with the photo.
	sidecar_candidates "$sdir" "$sstem"
	for sc in "${SC_LIST[@]}"; do
		[[ $sc == "$1" || -n ${seen[$sc]:-} || -d $sc ]] && continue
		seen[$sc]=1
		e=${sc##*.}
		case ",$SIDECAR_EXTS," in *",${e,,},"*) ;; *) continue ;; esac

		suf=${sc##*/}; suf=${suf#"$sstem"}             # .xmp | .CR2.xmp | _01.CR2.xmp
		mid=${suf%%.*}                                 # "" | _01 | _something
		# only take numbered variants of ourselves, not some other photo's sidecar
		[[ -z $mid || $mid =~ ^_[0-9]+$ ]] || continue
		# if a photo of its own carries that name, the sidecar belongs to it
		owner=${sc%.*}
		[[ $owner != "$1" && -n ${in_moveset[$owner]:-} ]] && continue

		((LOWER_EXT)) && suf=${suf,,}
		if ((RENAME)) && ((!keep)); then resolve_dest "$sc" "$ddir" "$dbase" "$suf" 0
		else resolve_dest "$sc" "$ddir" "${sc##*/}" "" 0; fi
		[[ $RD_ACT == place ]] && add_plan "$sc" "$RD_DEST" sidecar "$4"
	done
	return 0
}

# Dates for everything, from the cache where possible and exiftool otherwise.
load_cache
T_EXIF=$(now_ms)
read_exif_dates
took "$T_EXIF" "reading dates" "${#files[@]}"
T_PLAN=$(now_ms)

# --- pass 1: work out the wanted folder, name and extension for every file ---
declare -a c_dir=() c_base=() c_ext=() c_state=() c_move=() c_date=()
declare -A fmt_dir=() fmt_name=()

for i in "${!files[@]}"; do
	f=${files[i]}
	c_dir[i]=""; c_base[i]=""; c_ext[i]=""; c_state[i]=ok; c_move[i]=1
	[[ ${origins[i]} == src ]] && ((DO_COPY)) && c_move[i]=0

	d=${date_of[$f]:-}
	if [[ -n $d ]]; then
		((++n_exif))
	elif [[ $FALLBACK == skip ]]; then
		((++n_nodate)); c_state[i]=nodate; continue
	elif [[ $FALLBACK == unsorted ]]; then
		((++n_nodate)); c_state[i]=unsorted
		c_dir[i]="$TARGET/$UNSORTED_DIR"; c_base[i]=${f##*/}; continue
	else
		d=$(fs_date "$f" || true)
		if [[ -z $d ]]; then
			((++n_nodate)); ((++n_err)); warn "no date at all: $f"; c_state[i]=nodate; continue
		fi
		date_of[$f]=$d; date_src[$f]=fs; ((++n_fs))
	fi
	c_date[i]=$d
done

# --- pass 1b: turn all those dates into folder and file names in ONE date(1)
# call. Forking date(1) per file costs about a second per thousand photos, which
# is minutes of pure overhead on a large library.
format_dates

for i in "${!files[@]}"; do
	[[ ${c_state[i]} == ok ]] || continue
	f=${files[i]}
	key=${c_date[i]#@}
	sub=${fmt_dir[$key]:-}; nm=${fmt_name[$key]:-}
	if [[ -z $sub ]]; then
		warn "cannot make sense of the date '${c_date[i]#@}' for: $f"; ((++n_err)); c_state[i]=error; continue
	fi
	split_name "$f"
	ext=$SN_EXT; ((LOWER_EXT)) && ext=${ext,,}
	((RENAME)) || nm=$SN_STEM
	if [[ -z $nm ]]; then
		warn "empty file name from the format options for: $f"; ((++n_err)); c_state[i]=error; continue
	fi
	c_dir[i]="$TARGET/$sub"; c_base[i]=$nm; c_ext[i]=$ext
done

# Which copy of a set of identical files do we keep? Order on disk is a poor
# reason to delete somebody's photo, so: a file that already sits exactly where
# it belongs wins (zero churn, and its sidecars stay primary), then one that is
# already in the library beats a fresh import, then the shortest name - copies
# are what carry "(1)" or " - Copy" suffixes. Ties fall back to scan order.
elect_survivor() { # <index...> -> PS_BEST
	local i rank len brank=9 blen=0 name better
	PS_BEST=-1
	for i in "$@"; do
		if [[ "${c_dir[i]}/${c_base[i]}${c_ext[i]}" == "${files[i]}" ]]; then rank=0
		elif [[ ${origins[i]} == tgt ]]; then rank=1
		else rank=2; fi
		name=${files[i]##*/}; len=${#name}
		better=0
		if ((PS_BEST < 0)); then better=1
		elif ((rank < brank)); then better=1
		elif ((rank == brank)) && ((len < blen)); then better=1
		fi
		((better)) && { PS_BEST=$i; brank=$rank; blen=$len; }
	done
	return 0
}

# --- pass 1b: with --dedupe-scope all, find duplicates by content alone -------
# The normal scope only compares files that end up wanting the same name, which
# misses copies whose extension differs (.CR2 vs .cr2, .jpg vs .jpeg) and, with
# --no-rename, copies with different names. Here every file is grouped by size
# first - two files can only be identical if their byte count matches, and
# photos hardly ever share an exact size unless they really are copies - and
# only those candidates are hashed.
declare -A c_dupof=()
if [[ $DEDUPE_SCOPE == all ]]; then
	declare -A by_size=()
	for i in "${!files[@]}"; do
		case ${c_state[i]} in ok | unsorted) ;; *) continue ;; esac
		by_size[$(file_size "${files[i]}")]+="$i "
	done
	for sz in "${!by_size[@]}"; do
		read -r -a group <<<"${by_size[$sz]}"
		((${#group[@]} > 1)) || continue
		declare -A by_hash=()
		for i in "${group[@]}"; do file_hash "${files[i]}"; by_hash[$FH]+="$i "; done
		for h in "${!by_hash[@]}"; do
			read -r -a twins <<<"${by_hash[$h]}"
			((${#twins[@]} > 1)) || continue
			elect_survivor "${twins[@]}"
			for i in "${twins[@]}"; do
				((i == PS_BEST)) && continue
				c_state[i]=cdup; c_dupof[i]=$PS_BEST; ((++n_dups))
			done
		done
		unset by_hash
	done
fi

# --- pass 2: files that already sit exactly where they belong keep their name.
# They have to claim it before anybody else can take it, otherwise a
# "... (1).jpg" next to it could grab the free base name and cause a pointless
# shuffle on every run.
declare -a c_dest=()
for i in "${!files[@]}"; do
	c_dest[i]=""
	[[ ${c_state[i]} == ok ]] || continue
	dst="${c_dir[i]}/${c_base[i]}${c_ext[i]}"
	[[ $dst == "${files[i]}" ]] || continue
	CUR_ORIGIN=${origins[i]}
	claimed[$dst]=${files[i]}
	add_plan "${files[i]}" "$dst" inplace 0
	c_dest[i]=$dst
	c_state[i]=done
done

# --- pass 3: everything else gets a free (or deduplicated) destination -------
# The sidecars of a duplicate that is about to be deleted must not be orphaned:
# they describe edits, and two byte-identical raws can carry completely
# different ones, so a differing edit is re-attached to the surviving photo as
# another darktable version (_01, _02, ...) instead of being thrown away.
plan_dup_sidecars() { # <duplicate> <its ext> <where the kept copy ends up>
	((SIDECARS)) || return 0
	local dup=$1 ext=$2 keepdst=$3
	local sdir sstem kdir kstem kext sc e suf mid owner target cmp tail slot pad cand
	local scname scmid scnum
	split_name "$dup"; sdir=$SN_DIR; sstem=$SN_STEM
	# The kept copy may well have a different extension than the duplicate
	# (.jpeg vs .JPG) once --dedupe-scope all is in play, so the new name is
	# rebuilt from the survivor's own stem and extension instead of pasting the
	# duplicate's suffix onto it.
	split_name "$keepdst"; kdir=$SN_DIR; kstem=$SN_STEM; kext=$SN_EXT
	local -A seen=()
	sidecar_candidates "$sdir" "$sstem"
	for sc in "${SC_LIST[@]}"; do
		[[ $sc == "$dup" || -n ${seen[$sc]:-} || -d $sc ]] && continue
		seen[$sc]=1
		e=${sc##*.}
		case ",$SIDECAR_EXTS," in *",${e,,},"*) ;; *) continue ;; esac
		suf=${sc##*/}; suf=${suf#"$sstem"}
		mid=${suf%%.*}
		[[ -z $mid || $mid =~ ^_[0-9]+$ ]] || continue
		owner=${sc%.*}
		[[ $owner != "$dup" && -n ${in_moveset[$owner]:-} ]] && continue

		case $DUP_SIDECARS in
		delete) add_plan "$sc" "" dupside 1; continue ;;
		keep) warn "sidecar of a deleted duplicate, left where it is: $sc"; continue ;;
		esac

		# IMG.CR2.xmp keeps the photo extension, IMG.xmp does not - mirror that
		# with the survivor's extension rather than the duplicate's.
		tail=".$e"
		((LOWER_EXT)) && tail=${tail,,}
		[[ -n $ext && ${suf#"$mid"} == "$ext"* ]] && tail="$kext$tail"

		# The duplicate can be the copy that was already correctly named, in
		# which case its sidecars already sit exactly where the survivor wants
		# them. They belong to the survivor from now on - leave them untouched.
		# Without this they would be compared against themselves, found
		# "identical" and deleted.
		if [[ ${sc%/*} == "$kdir" ]]; then
			scname=${sc##*/}; scmid=${scname#"$kstem"}
			if [[ $scmid != "$scname" ]]; then
				scnum=${scmid%"$tail"}
				if [[ $scnum != "$scmid" ]] && [[ -z $scnum || $scnum =~ ^_[0-9]+$ ]]; then
					continue
				fi
			fi
		fi

		target="$kdir/$kstem$tail"
		if [[ ! -e $target && -z ${claimed[$target]:-} ]]; then
			claimed[$target]=$sc; add_plan "$sc" "$target" sidecar 1; continue
		fi
		# same edit as the kept photo's own sidecar? then there is nothing to save
		cmp=$target
		[[ ! -e $cmp && -n ${claimed[$target]:-} ]] && cmp=${claimed[$target]}
		if [[ -e $cmp ]] && same_content "$sc" "$cmp"; then
			add_plan "$sc" "$cmp" dupside 1; continue
		fi
		# a genuinely different edit: give it the next free darktable slot
		slot=0; cand=''
		while ((++slot <= 99)); do
			pad=$(printf '_%02d' "$slot")
			if [[ ! -e "$kdir/$kstem$pad$tail" && -z ${claimed["$kdir/$kstem$pad$tail"]:-} ]]; then
				cand="$kdir/$kstem$pad$tail"; break
			fi
		done
		if [[ -n $cand ]]; then
			claimed[$cand]=$sc; add_plan "$sc" "$cand" sidecar 1
		else
			warn "no free slot to keep this edit, leaving it alone: $sc"
		fi
	done
	return 0
}

for i in "${!files[@]}"; do
	f=${files[i]}
	CUR_ORIGIN=${origins[i]}
	case ${c_state[i]} in
	done | cdup) continue ;;      # cdup is handled in pass 4, once its twin has a home
	nodate) add_plan "$f" "" nodate 0; continue ;;
	error) add_plan "$f" "" error 0; continue ;;
	esac

	resolve_dest "$f" "${c_dir[i]}" "${c_base[i]}" "${c_ext[i]}" 1
	c_dest[i]=$RD_DEST
	case $RD_ACT in
	error) ((++n_err)); warn "could not find a free name for: $f"; add_plan "$f" "" error 0 ;;
	inplace) add_plan "$f" "$RD_DEST" inplace 0 ;;
	dup)
		add_plan "$f" "$RD_DEST" dup "${c_move[i]}"
		# only when the duplicate really goes away (never in --copy mode)
		[[ $DEDUPE == delete ]] && ((c_move[i])) && plan_dup_sidecars "$f" "${c_ext[i]}" "$RD_KEEP"
		;;
	place)
		add_plan "$f" "$RD_DEST" place "${c_move[i]}"
		if [[ ${c_state[i]} == unsorted ]]; then
			plan_sidecars "$f" "$RD_DEST" "${c_ext[i]}" "${c_move[i]}" 1
		else
			plan_sidecars "$f" "$RD_DEST" "${c_ext[i]}" "${c_move[i]}"
		fi
		;;
	esac
done

# --- pass 4: content duplicates, now that the copy we keep has a destination --
for i in "${!files[@]}"; do
	[[ ${c_state[i]} == cdup ]] || continue
	f=${files[i]}
	CUR_ORIGIN=${origins[i]}
	twin=${c_dupof[i]}
	keepdst=${c_dest[twin]:-${files[twin]}}
	case $DEDUPE in
	keep)
		# not a name clash at all, so it just gets sorted like any other file
		resolve_dest "$f" "${c_dir[i]}" "${c_base[i]}" "${c_ext[i]}" 0
		c_dest[i]=$RD_DEST
		case $RD_ACT in
		place)
			add_plan "$f" "$RD_DEST" place "${c_move[i]}"
			plan_sidecars "$f" "$RD_DEST" "${c_ext[i]}" "${c_move[i]}" \
				"$([[ ${c_state[i]} == unsorted ]] && echo 1 || echo 0)"
			;;
		inplace) add_plan "$f" "$RD_DEST" inplace 0 ;;
		*) ((++n_err)); warn "could not find a free name for: $f"; add_plan "$f" "" error 0 ;;
		esac
		;;
	skip) add_plan "$f" "${files[twin]}" dup 0 ;;
	delete)
		add_plan "$f" "$keepdst" dup "${c_move[i]}"
		((c_move[i])) && plan_dup_sidecars "$f" "${c_ext[i]}" "$keepdst"
		;;
	esac
done

took "$T_PLAN" "working out where everything goes" "${#files[@]}"

# --------------------------------------------------------------- the report ---
n_place=0 n_copy=0 n_inplace=0 n_dupskip=0 n_dupdel=0 n_side=0 n_skipnodate=0 n_dupside=0
for i in "${!p_src[@]}"; do
	case ${p_act[i]} in
	place) ((p_move[i])) && ((++n_place)) || ((++n_copy)) ;;
	sidecar) ((++n_side)) ;;
	inplace) ((++n_inplace)) ;;
	dup) if [[ $DEDUPE == delete ]] && ((p_move[i])); then ((++n_dupdel)); else ((++n_dupskip)); fi ;;
	nodate) ((++n_skipnodate)) ;;
	dupside) ((++n_dupside)) ;;
	esac
done

if ((VERBOSE)); then
	for i in "${!p_src[@]}"; do
		case ${p_act[i]} in
		place | sidecar)
			if ((p_move[i])); then chat "MOVE  ${p_src[i]}  ->  ${p_dst[i]}"
			else chat "COPY  ${p_src[i]}  ->  ${p_dst[i]}"; fi ;;
		inplace) chat "KEEP  ${p_src[i]} (already in place)" ;;
		dup) if [[ $DEDUPE == delete ]] && ((p_move[i])); then chat "DELETE dup  ${p_src[i]} (== ${p_dst[i]})"
			else chat "SKIP dup  ${p_src[i]} (== ${p_dst[i]})"; fi ;;
		dupside) chat "DELETE sidecar of a duplicate  ${p_src[i]}" ;;
		nodate) chat "SKIP no date  ${p_src[i]}" ;;
		error) chat "ERROR  ${p_src[i]}" ;;
		esac
	done
fi

summary() {
	printf '\n%s\n' "summary${1:+ ($1)}:"
	printf '  scanned              %d\n' "${#files[@]}"
	printf '  date from EXIF       %d\n' "$n_exif"
	printf '  date from filesystem %d\n' "$n_fs"
	((n_nodate)) && printf '  without any date     %d\n' "$n_nodate"
	((n_place)) && printf '  to move              %d\n' "$n_place"
	((n_copy)) && printf '  to copy              %d\n' "$n_copy"
	((n_side)) && printf '  sidecars             %d\n' "$n_side"
	((n_inplace)) && printf '  already in place     %d\n' "$n_inplace"
	printf '  duplicates found     %d\n' "$n_dups"
	((n_dupskip)) && printf '  duplicates skipped   %d\n' "$n_dupskip"
	((n_dupdel)) && printf '  duplicates to delete %d\n' "$n_dupdel"
	((n_dupside)) && printf '  their sidecars       %d (to delete as well)\n' "$n_dupside"
	((n_skipnodate)) && printf '  skipped (no date)    %d\n' "$n_skipnodate"
	((n_err)) && printf '  problems             %d\n' "$n_err"
	return 0
}

if ((DRY_RUN)); then
	summary "dry run - nothing was changed"
	((VERBOSE)) || info $'\nrun again with -v to see every single operation.'
	exit 0
fi

if ((n_dupdel + n_dupside)) && ((!ASSUME_YES)); then
	if [[ -t 0 ]]; then
		summary "about to run"
		read -r -p "delete $((n_dupdel + n_dupside)) duplicate file(s) permanently? [y/N] " a
		[[ ${a,,} == y* ]] || die "aborted."
	else
		die "--dedupe delete would delete $((n_dupdel + n_dupside)) file(s); pass --yes to confirm (no terminal to ask on)"
	fi
fi

# ------------------------------------------------------------------ execute ---
log() { [[ -n $LOG_FILE ]] && printf '%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" "$3" >>"$LOG_FILE"; return 0; }
[[ -n $LOG_FILE && ! -s $LOG_FILE ]] && printf '#when\taction\tfrom\tto\n' >>"$LOG_FILE"

T_MOVE=$(now_ms)
done_place=0 done_copy=0 done_del=0 done_side=0 done_side_del=0 fail=0 n_degraded=0 n_retried=0
declare -a failures=()

note_failure() { # <path> <reason>
	((++fail)); failures+=("$1"$'\t'"$2")
	warn "$2: $1"
	log failed "$1" "${2//$'\t'/ }"
}

# Copy, giving up attributes step by step rather than the file. Filesystems
# without unix permissions (exFAT, FAT32, NTFS, SMB/NFS shares, Windows drives
# under WSL) refuse mode/owner/ACLs with "Operation not supported", but cp
# writes the data first and only then applies attributes - so if all the bytes
# arrived, the copy is fine and only the metadata was rejected. Deciding this by
# size instead of by parsing cp's message also survives non-English locales.
TR_ERR='' TR_DEGRADED=0
copy_file() { # <src> <dst> -> 0 ok (TR_DEGRADED tells whether attributes were lost)
	local src=$1 dst=$2 err
	case $PRESERVE in
	all) err=$(cp -p -- "$src" "$dst" 2>&1) && return 0 ;;
	timestamps)
		if ((CP_PRESERVE_TS)); then
			err=$(cp --preserve=timestamps -- "$src" "$dst" 2>&1) && return 0
		elif err=$(cp -- "$src" "$dst" 2>&1); then
			touch -r "$src" -- "$dst" 2>/dev/null
			return 0
		fi ;;
	none) err=$(cp -- "$src" "$dst" 2>&1) && return 0 ;;
	esac
	# Only step down to fewer attributes when the data itself clearly made it.
	# A genuine failure must stay a failure so the retry loop can try again with
	# full preservation, instead of quietly downgrading it.
	if same_size "$src" "$dst"; then
		TR_DEGRADED=1; TR_ERR=$err
		touch -r "$src" -- "$dst" 2>/dev/null || TR_ERR="$err (and the timestamps could not be set either)"
		return 0
	fi
	TR_ERR=$err
	[[ -e $dst ]] && rm -f -- "$dst" 2>/dev/null
	return 1
}

move_file() { # <src> <dst> -> 0 ok
	local src=$1 dst=$2 err
	if err=$(mv -- "$src" "$dst" 2>&1); then return 0; fi
	# Across filesystems mv is a copy plus a delete, so it can fail on the
	# attributes or on removing the original while the data is already there.
	if [[ ! -e $src && -e $dst ]]; then TR_DEGRADED=1; TR_ERR=$err; return 0; fi
	if [[ -e $src ]] && content_matches "$src" "$dst"; then
		TR_DEGRADED=1; TR_ERR=$err
		touch -r "$src" -- "$dst" 2>/dev/null || true
		rm -f -- "$src" 2>/dev/null && return 0
		TR_ERR="copied, but the original could not be removed: $err"
		return 1
	fi
	TR_ERR=$err
	[[ -e $src && -e $dst ]] && rm -f -- "$dst" 2>/dev/null   # drop a partial copy
	return 1
}

transfer() { # <src> <dst> <move?> -> 0 ok
	local src=$1 dst=$2 move=$3 try=0 wait=1
	TR_ERR=''; TR_DEGRADED=0
	while :; do
		((++try))
		if ((move)); then move_file "$src" "$dst" && break
		else copy_file "$src" "$dst" && break; fi
		((try > RETRIES)) && return 1
		[[ -e $src ]] || return 1            # nothing left to retry with
		chat "retry $try/$RETRIES after \"$TR_ERR\": $src"
		sleep "$wait"; wait=$((wait * 2))
	done
	((try > 1)) && ((++n_retried))
	((TR_DEGRADED)) && { ((++n_degraded)); chat "attributes not preserved: $dst ($TR_ERR)"; }
	return 0
}

for i in "${!p_src[@]}"; do
	src=${p_src[i]} dst=${p_dst[i]} act=${p_act[i]}
	case $act in
	inplace | nodate | error) continue ;;
	dupside)
		if rm -f -- "$src"; then ((++done_side_del)); log delete-duplicate-sidecar "$src" "$dst"
		else note_failure "$src" "could not delete duplicate sidecar"; fi
		continue ;;
	dup)
		if [[ $DEDUPE == delete ]] && ((p_move[i])); then
			if rm -f -- "$src"; then ((++done_del)); log delete-duplicate "$src" "$dst"
			else note_failure "$src" "could not delete duplicate"; fi
		fi
		continue ;;
	esac

	# Something still sitting on our destination can only be a file that is
	# itself waiting to be moved - park it in the staging folder first.
	if [[ -e $dst ]]; then
		j=${plan_of[$dst]:-}
		if [[ -n $j ]] && ((j > i)) && [[ ${p_act[j]} != inplace ]]; then
			mkdir -p -- "$STAGE" || { note_failure "$dst" "cannot create staging dir"; continue; }
			if mv -- "$dst" "$STAGE/$j"; then p_src[j]="$STAGE/$j"
			else note_failure "$dst" "cannot move blocking file out of the way"; continue; fi
		else
			note_failure "$dst" "destination unexpectedly exists, skipped"; continue
		fi
	fi

	mkdir -p -- "${dst%/*}" || { note_failure "$src" "cannot create ${dst%/*}"; continue; }
	if transfer "$src" "$dst" "${p_move[i]}"; then
		if [[ $act == sidecar ]]; then ((++done_side))
		elif ((p_move[i])); then ((++done_place))
		else ((++done_copy)); fi
		if ((p_move[i])); then
			log "$([[ ${p_org[i]} == tgt ]] && echo reorganize || echo move)" "$src" "$dst"
		else log copy "$src" "$dst"; fi
	else
		note_failure "$src" "${TR_ERR:-transfer failed}"
	fi
done

took "$T_MOVE" "moving files" "${#p_src[@]}"
write_cache

if ((PRUNE_EMPTY)); then
	# Reorganising empties folders inside the target as well ("Urlaub 2019" once
	# its photos moved into 2019/07), so those get cleaned up too. -mindepth 1
	# keeps the roots themselves, and freshly filled folders are not empty.
	declare -a roots=("${SOURCES[@]}")
	{ ((IN_PLACE)) || ((REORGANIZE)); } && roots+=("$TARGET")
	declare -A done_root=()
	for s in "${roots[@]}"; do
		[[ -n ${done_root[$s]:-} ]] && continue
		done_root[$s]=1
		find "$s" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
	done
fi

summary
((done_place)) && printf '  moved                %d\n' "$done_place"
((done_copy)) && printf '  copied               %d\n' "$done_copy"
((done_side)) && printf '  sidecars handled     %d\n' "$done_side"
((done_del)) && printf '  duplicates deleted   %d\n' "$done_del"
((done_side_del)) && printf '  their sidecars       %d (deleted as well)\n' "$done_side_del"
((n_degraded)) && printf '  attributes not kept  %d (data and timestamps are intact)\n' "$n_degraded"
((n_retried)) && printf '  succeeded on retry   %d\n' "$n_retried"
((fail)) && printf '  FAILED               %d\n' "$fail"
[[ -n $LOG_FILE ]] && printf '  log                  %s\n' "$LOG_FILE"

# The whole point of a summary is that you do not have to scroll back, so name
# the files that are still not where they should be.
if ((${#failures[@]})); then
	printf '\nstill not sorted after %d retr%s - left untouched:\n' \
		"$RETRIES" "$([[ $RETRIES == 1 ]] && echo y || echo ies)"
	shown=0
	for entry in "${failures[@]}"; do
		if ((shown >= 50)); then
			printf '  ... and %d more%s\n' $((${#failures[@]} - 50)) \
				"${LOG_FILE:+ (all of them are in $LOG_FILE)}"
			break
		fi
		((++shown))
		printf '  %s\n' "${entry%%$'\t'*}"
		[[ ${entry#*$'\t'} != "${entry%%$'\t'*}" ]] && printf '      %s\n' "${entry#*$'\t'}"
	done
fi

((fail == 0))
