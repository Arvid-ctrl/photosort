#!/usr/bin/env bash
#
# arvid-sort.sh — sort photos from --source into a destination.

set -euo pipefail

usage() {
  cat <<'EOF'
  Usage: arvid-sort.sh -s <source> [options]

  Sort photos from a source directory.

  Options:
    -s, --source <path>   Source directory to sort
    -t, --target          Target directory to sort into
    -n, --dryrun          Dryrun. Do not move files
    -v, --verbose         Additional logging
    --no-exif             Ignore missing exiftool installation
    --no-rename           Files keep their original name
    -h, --help            Show this help and exit
EOF
}

# inside <child> <parent>
# True if $1 is the same as, or strictly inside, $2.
inside() {
  local child parent
  child=$(realpath -m -- "$1") || return 1
  parent=$(realpath -m -- "$2") || return 1
  [[ $child == "$parent" || $child == "$parent"/* ]]
}

discover() {
  local -n out=$1
  local dir=$2
  out=()
  while IFS= read -r -d '' f; do
    [[ $VERBOSE == true ]] && echo "Found $f" >&2
    out+=("$f")
  done < <(find "$dir" -type f -print0)
}

# is_photo <path>
# Returns 0 (true) if $1 is a regular file with a known photo extension.
is_photo() {
  [[ -f $1 ]] || return 1
  case ${1,,} in # ${1,,} = lowercase the whole name
  *.jpg | *.jpeg | *.jfif | *.jpe | \
    *.png | *.gif | *.webp | *.tif | *.tiff | \
    *.cr2 | *.cr3 | *.nef | *.arw | *.dng | \
    *.heic | *.heif | *.raf | *.rw2 | \
    *.bmp | *.svg)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# get_exif_all <arr> <file>...
# Populates associative array arr: arr[path] = "YYYY-MM-DD HH:MM:SS"
# for each file that has a usable EXIF date. No entry = no/garbage date.
# TODO:think about using epoch time for fallbacks since they are OS independent
get_exif_all() {
  local -n out=$1
  shift
  local list fmt path
  out=()
  local date

  command -v exiftool >/dev/null || return 0
  list=$(mktemp) || return 1
  printf '%s\n' "$@" >"$list"

  # SAME format string as get_exif — DTO, CreateDate, path, tab-separated
  fmt=$'${DateTimeOriginal}\t${CreateDate}\t$FilePath'

  while IFS=$'\t' read -r dto cd path; do
    date=$dto
    [[ $date == "-" || -z $date ]] && date=$cd # fall back to CreateDate
    [[ $date == "-" || -z $date ]] && continue # no date
    [[ $date == 0000-* ]] && continue          # zero-date garbage
    out[$path]=$date
  done < <(exiftool -p "$fmt" -f -d '%Y-%m-%d %H:%M:%S' -@ "$list" 2>/dev/null)
  rm -f "$list"
}

ensure_dir() {
  local path="$1"

  if [[ -e "$path" ]]; then
    return 0
  fi

  if [[ $DRYRUN == true ]]; then
    [[ -n ${dryrunDirs["$path"]+x} ]] && return 0
    [[ $VERBOSE == true ]] && echo "Would create $path." >&2
    dryrunDirs["$path"]=true
  else
    [[ $VERBOSE == true ]] && echo "creating $path" >&2
    mkdir -p "$path"
  fi
}

# check if photos are byte-identical
check_hash() {
  local ha hb
  ha=$(sha1sum "$1" | cut -d' ' -f1)
  hb=$(sha1sum "$2" | cut -d' ' -f1)
  [[ $ha == $hb ]]
}

SOURCE=""
TARGET=""
DRYRUN=false
MODE=move
RENAME=true
DEDUP=false
VERBOSE=false
NO_EXIF=false
declare -A SRC_EXIF
declare -a SRC_FILES #array of discovered files

declare -a TARGET_FILES #array of discovered files in the target
declare -A TARGET_EXIF
declare -A EXIF_TARGET

declare -A claimedPaths
declare -A dryrunDirs

while [[ $# -gt 0 ]]; do
  case "$1" in
  -s | --source)
    # value is the next argument
    if [[ $# -lt 2 || "$2" == -* ]]; then
      echo "Error: --source requires a path argument" >&2
      exit 1
    fi
    SOURCE="$2"
    shift 2 # consume both the flag AND its value
    ;;
  -t | --target)
    # value is the next argument
    if [[ $# -lt 2 || "$2" == -* ]]; then
      echo "Error: --target requires a path argument" >&2
      exit 1
    fi
    TARGET="$2"
    shift 2 # consume both the flag AND its value
    ;;
  -n | --dryrun)
    # value is the next argument
    DRYRUN=true
    shift 1 # consume only the flag
    ;;
  --move)
    # value is the next argument
    MODE=move
    shift 1 # consume only the flag
    ;;
  --copy)
    # value is the next argument
    MODE=copy
    shift 1 # consume only the flag
    ;;
  --no-rename)
    # value is the next argument
    RENAME=false
    shift 1 # consume only the flag
    ;;
  --dedup)
    # value is the next argument
    DEDUP=true
    shift 1 # consume only the flag
    ;;
  -v | --verbose)
    VERBOSE=true
    shift 1 # consume only the flag
    ;;
  --no-exif)
    NO_EXIF=true
    shift 1 # consume only the flag
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
  esac
done

if [[ -z $SOURCE || ! -d $SOURCE ]]; then
  echo -e "error: Source must be a valid directory." >&2
  exit 1
fi

TARGET=${TARGET:-$SOURCE} # if target isn't set, set it to source

[[ $VERBOSE == true ]] && echo "Scanning $SOURCE." >&2
discover SRC_FILES "$SOURCE"

if [[ -d $TARGET ]] && ! inside "$TARGET" "$SOURCE"; then
  [[ $VERBOSE == true ]] && echo "target is outside source."
  discover TARGET_FILES "$TARGET"
  get_exif_all TARGET_EXIF "${TARGET_FILES[@]}"
else
  for f in "${SRC_FILES[@]}"; do
    case "$f" in
    "${TARGET%/}/"*)
      TARGET_FILES+=("$f")
      ;;
    esac
  done
  get_exif_all TARGET_EXIF "${TARGET_FILES[@]}"
fi

get_exif_all SRC_EXIF "${SRC_FILES[@]}"
declare no_date=0 # TODO: use for counting

declare -A EXIF_TARGET

if [[ $DEDUP == true ]]; then
  for path in "${!TARGET_EXIF[@]}"; do
    EXIF_TARGET[${TARGET_EXIF["$path"]}]+="$path"$'\n'
  done
fi

for f in "${SRC_FILES[@]}"; do
  is_photo "$f" || continue
  [[ -n ${SRC_EXIF[$f]} ]] || continue # no EXIF date -> fallback/unsorted
  date=${SRC_EXIF[$f]}

  declare year=${date:0:4}
  declare month=${date:5:2}
  declare day=${date:8:2}

  declare dest=""
  declare dest_dir="$TARGET/$year/$month/$day"

  ensure_dir "$dest_dir"

  declare file_name=${f##*/}
  declare base_name=${file_name%.*}
  declare file_ext=${f##*.}
  declare target_name=$base_name

  if [[ $RENAME == true ]]; then
    # TODO: more logic needed for configurable names
    target_name="$date.$file_ext"
  fi

  dest="$dest_dir/$target_name"

  if [[ $DEDUP == true && -n ${EXIF_TARGET["$date"]+x} ]]; then
    while IFS= read -r cand; do
      [[ -n $cand ]] || continue

      if inside "$cand" "$dest_dir" && check_hash "$f" "$cand"; then
        # TODO: check which file has the shorter name and keep it
        dest_dir="$TARGET/duplicates/$year/$month/$day"
        ensure_dir "$dest_dir"
        dest="$dest_dir/$target_name"
        break
      fi

    done <<<"${EXIF_TARGET["$date"]}"
  fi

  declare dup_suffix=0

  while [[ -e "$dest" || -n "${claimedPaths["$dest"]+x}" ]]; do
    dup_suffix++
    target_name="$base_name($dup_suffix).$file_ext"
    dest="$dest_dir/$target_name"
  done

  claimedPaths["$dest"]=true

  if [[ $DRYRUN == true ]]; then
    [[ $VERBOSE == true ]] && echo "Would move $f to $dest" >&2
  elif [[ $MODE == move ]]; then
    [[ $VERBOSE == true ]] && echo "Moving $f to $dest" >&2
    if ! mv "$f" "$dest" 2>/dev/null; then
      echo -e "error: could not move $f to $dest" >&2
    fi
  elif [[ $MODE == copy ]]; then
    [[ $VERBOSE == true ]] && echo "Copying $f to $dest" >&2
    if ! cp "$f" "$dest" 2>/dev/null; then
      echo -e "error: could not copy $f to $dest" >&2
    fi
  fi

  # TODO:
  # check for sidecars
  # rename sidecars if needed
  # check for conflicts (file or sidecar)

done
