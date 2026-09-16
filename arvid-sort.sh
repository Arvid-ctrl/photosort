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
    -h, --help            Show this help and exit
EOF
}

path_exists() {
  [[ -e $1 ]]
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
get_exif_all() {
  local -n out=$1
  shift
  local list fmt path
  out=()

  command -v exiftool >/dev/null || return 0
  list=$(mktemp) || return 1
  printf '%s\n' "$@" >"$list"

  # SAME format string as get_exif — DTO, CreateDate, path, tab-separated
  fmt=$'${DateTimeOriginal}\t${CreateDate}\t$FilePath'

  while IFS=$'\t' read -r dto cd path; do
    local date=$dto
    [[ $date == "-" || -z $date ]] && date=$cd     # fall back to CreateDate
    [[ $date == "-" || -z $date ]] && continue     # no date
    [[ $date == 0000-* ]] && continue              # zero-date garbage
    out[$path]=$date
  done < <(exiftool -p "$fmt" -f -d '%Y-%m-%d %H:%M:%S' -@ "$list" 2>/dev/null)
  rm -f "$list"
}


SOURCE=""
TARGET=""
DRYRUN=false
VERBOSE=false
declare -A exif
declare -a FILES #array of discovered files
declare -a TARGET_FILES #array of discovered files in the target

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
  -v | --verbose)
    VERBOSE=true
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

if path_exists "$SOURCE"; then
  discover FILES "$SOURCE";

  if path_exists "$TARGET" && ! inside "$TARGET" "$SOURCE"; then
    discover TARGET_FILES "$SOURCE";

  fi
fi


get_exif_all EXIF "${FILES[@]}"        # one exiftool process for the whole source

for f in "${FILES[@]}"; do
  is_photo "$f" || continue
  [[ -n ${EXIF[$f]} ]] || continue     # no EXIF date -> fallback/unsorted
  date=${EXIF[$f]}
  # ... compute dest from $date, claim, mv, sidecar ...
done

get_exif exif "$some_file"
if [[ ${exif[found]} == 1 ]]; then
  echo "${exif[YYYY]} ${exif[MM]} ${exif[DD]} ${exif[HH]} ${exif[SS]}"
fi

discover FILES "$SOURCE"


check_duplicate() {

  local ha hb
      ha=$(sha1sum "$1" | cut -d' ' -f1)
      hb=$(sha1sum "$2" | cut -d' ' -f1)
      [[ $ha == $hb ]]
  }
}
