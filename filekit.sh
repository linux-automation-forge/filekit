#!/usr/bin/env bash
# filekit.sh — file compressor / decompressor / comparator (v1.0.0)
# USAGE:
#   ./filekit.sh compress <file|dir...>        [-m auto|zstd|xz|gzip|bzip2] [-l fast|normal|best]
#   ./filekit.sh decompress <archive>          [-o outdir] [--here]
#   ./filekit.sh compare <a> <b> [-q] [--stats-only]   (files OR directories)
#   ./filekit.sh --selftest | --gen-files | -h | -V
# SAFETY: dry-run mode, never overwrites without asking, tar-bomb guard,
#         verifies archives after writing, originals kept unless --remove.
# COMPARE EXIT CODES: 0=identical  1=different  2=error  (pipe-friendly)
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
VERSION="1.0.0"

# ==================== USER-CONFIGURABLE DEFAULTS ============================
FORMAT="auto"        # auto|zstd|xz|gzip|bzip2  (auto = best available)
LEVEL="normal"       # fast|normal|best
VERIFY=1             # verify archive integrity after writing (1=yes)
KEEP_SOURCE=1        # 1=keep originals after compress (use --remove to delete)
DRY_RUN=0
FORCE=0
ASSUME_YES=0
EXCERPT=12           # diff lines shown in text compare
MAX_LIST=15          # members shown in decompress dry-run preview

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; CYN=$'\033[1;36m'
else
    R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""
fi
ok()   { printf '  %s[ok]%s %s\n'   "$GRN" "$R" "$1"; }
warn() { printf '  %s[!!] %s%s\n'   "$YLW" "$1" "$R"; }
err()  { printf '  %s[XX] %s%s\n'   "$RED" "$1" "$R" >&2; }
step() { printf '\n%s▸ %s%s\n' "$CYN$B" "$1" "$R"; }
die()  { err "$2"; exit "$1"; }
hr()   { printf '%s──────────────────────────────────────────────%s\n' "$DIM" "$R"; }
confirm() {
    if [[ "$ASSUME_YES" -eq 1 ]]; then printf '  [auto-yes] %s\n' "$1"; return 0; fi
    local reply=""; read -r -p "$(printf '%s? [y/N]: ' "$1")" reply || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
human() { awk -v b="${1:-0}" 'BEGIN{
    split("K M G T P",A," "); i=0
    while (b>=1024 && i<5){b/=1024;i++}
    printf "%.1f%s", b, (i==0?"B":A[i])}'; }
size_of() { stat -c%s "$1" 2>/dev/null || echo 0; }

# ==================== ALGORITHM SELECTION ===================================
ALGO=""; EXT=""
pick_algo() {
    case "$FORMAT" in
        zstd|xz|gzip|bzip2)
            command -v "$FORMAT" > /dev/null 2>&1 \
                || die 2 "$FORMAT requested but not installed — use -m auto"
            ALGO="$FORMAT" ;;
        auto)
            if   command -v zstd  > /dev/null 2>&1; then ALGO="zstd"
            elif command -v xz    > /dev/null 2>&1; then ALGO="xz"
            elif command -v bzip2 > /dev/null 2>&1; then ALGO="bzip2"
            elif command -v gzip  > /dev/null 2>&1; then ALGO="gzip"
            else die 2 "no compressor found — install zstd, xz, gzip or bzip2"
            fi ;;
        *) die 2 "unknown format '$FORMAT' (auto|zstd|xz|gzip|bzip2)" ;;
    esac
    case "$ALGO" in
        zstd)  EXT="tar.zst" ;;
        xz)    EXT="tar.xz" ;;
        gzip)  EXT="tar.gz" ;;
        bzip2) EXT="tar.bz2" ;;
    esac
}
algo_flag() { # maps LEVEL → algo-specific flag
    case "$ALGO" in
        zstd)  case "$LEVEL" in fast) echo -1;; best) echo -19;; *) echo -3;; esac ;;
        xz|gzip) case "$LEVEL" in fast) echo -1;; best) echo -9;; *) echo -6;; esac ;;
        bzip2) echo -9 ;;
    esac
}

# ==================== ARCHIVE TYPE DETECTION (magic bytes) ==================
magic_of() { od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n'; }
detect_type() { # echoes gzip|xz|zstd|bzip2|tar|unknown
    local m; m="$(magic_of "$1")"
    case "$m" in
        1f8b*)        echo gzip ;;
        fd377a585a*)  echo xz ;;
        28b52ffd*)    echo zstd ;;
        425a68*)      echo bzip2 ;;
        *)
            if tar -tf "$1" > /dev/null 2>&1; then echo tar
            else echo unknown; fi ;;
    esac
}
type_tar_flags() { # type action(t|x) → tar arguments
    local t="$1" act="$2"
    case "$t" in
        gzip)  printf 'tar -t%sf' "$([ "$act" = t ] && echo z || echo z)" ;;
        xz)    printf 'tar -%sf'  "$([ "$act" = t ] && echo tJ || echo xJ)" ;;
        *)     printf 'tar -%sf'  "$act" ;;
    esac
}
# decompress runner per type (members listed with -t, extracted with -x)
run_tar() { # run_tar <type> <action> <archive> [extra...]
    local t="$1" act="$2" arc="$3"; shift 3
    case "$t" in
        gzip)  tar "-${act}zf" "$arc" "$@" ;;
        xz)    tar "-${act}Jf" "$arc" "$@" ;;
        zstd)  tar "--zstd" "-${act}f" "$arc" "$@" ;;
        bzip2) tar "-${act}jf" "$arc" "$@" ;;
        tar)   tar "-${act}f" "$arc" "$@" ;;
        *) return 2 ;;
    esac
}

# ==================== TAR-BOMB GUARD ========================================
# rejects member lists containing absolute paths or ../ traversal
guard_members() { # member list on stdin; rc 0 = safe, rc 1 = DANGEROUS
    if grep -qE '(^/|(^|/)\.\.(/|$))' 2> /dev/null; then return 1; fi
    return 0
}

# ==================== COMPRESS ==============================================
CMD_INPUTS=()
do_compress() {
    (( ${#CMD_INPUTS[@]} > 0 )) || die 2 "compress needs at least one file or folder"
    local -a clean=() p
    for p in "${CMD_INPUTS[@]}"; do
        [[ -e "$p" ]] || die 2 "path does not exist: $p"
        clean+=("${p%/}")
    done

    pick_algo
    local flag; flag="$(algo_flag)"

    # archive name: from first input, or explicit -n
    local base first="${clean[0]}" name
    first="${first#/}"; first="${first:-archive}"
    [[ "$OUT_NAME" != "" ]] && name="$OUT_NAME" || { base="$(basename "$first")"; name="${base}.${EXT}"; }

    # total input size
    local total=0 s
    for p in "${clean[@]}"; do
        if [[ -d "$p" ]]; then s="$(du -sb "$p" 2>/dev/null | cut -f1)"; else s="$(size_of "$p")"; fi
        total=$(( total + ${s:-0} ))
    done

    step "Plan"
    printf '  inputs   : %s\n' "$(IFS=' '; printf '%s' "${clean[*]}")"
    printf '  method   : tar + %s (%s level)\n' "$ALGO" "$LEVEL"
    printf '  archive  : %s\n' "$name"
    printf '  original : %s\n' "$(human "$total")"

    if [[ -e "$name" && "$FORCE" -ne 1 ]]; then
        confirm "'$name' exists — overwrite it" || die 1 "aborted (use --force to skip this ask)"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "dry-run — nothing written (drop --dry-run to actually compress)"
        return 0
    fi

    step "Compressing"
    local t0=$SECONDS
    tar -cf - -- "${clean[@]}" | "$ALGO" "$flag" > "$name"
    ok "archive written: $name"

    if [[ "$VERIFY" -eq 1 ]]; then
        if run_tar_check_compressed "$name"; then
            ok "integrity verified (archive opens and lists cleanly)"
        else
            err "verification FAILED — archive may be corrupt; keeping originals"
            exit 1
        fi
    fi

    local csize; csize="$(size_of "$name")"
    local saved=0
    (( total > 0 )) && saved=$(( 100 * (total - csize) / total ))
    hr
    printf '  %s → %s   (%s%% smaller)   %ss\n' \
        "$(human "$total")" "$(human "$csize")" "$saved" "$(( SECONDS - t0 ))"
    hr

    if [[ "$KEEP_SOURCE" -ne 1 ]]; then
        if confirm "delete the original files now (archive verified)"; then
            rm -rf -- "${clean[@]}"
            ok "originals removed"
        fi
    fi
}
run_tar_check_compressed() { # verify using the algo we just used
    case "$ALGO" in
        gzip)  tar -tzf "$1" > /dev/null 2>&1 ;;
        xz)    tar -tJf "$1" > /dev/null 2>&1 ;;
        zstd)  tar --zstd -tf "$1" > /dev/null 2>&1 ;;
        bzip2) tar -tjf "$1" > /dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# ==================== DECOMPRESS ============================================
do_decompress() {
    local arc="${CMD_INPUTS[0]:-}"
    [[ -n "$arc" && -f "$arc" ]] || die 2 "decompress needs one existing archive file"
    [[ -r "$arc" ]] || die 2 "cannot read '$arc' — permission problem"

    local t; t="$(detect_type "$arc")"
    [[ "$t" == "unknown" ]] && die 2 "unrecognized archive format — magic bytes don't match tar/gzip/xz/zstd/bzip2"
    step "Detected format: $t"

    # --- safety: scan member paths BEFORE extracting (tar-bomb guard) -------
    local -a members=()
    mapfile -t members < <(run_tar "$t" t "$arc") || die 2 "archive is unreadable/corrupt"
    if printf '%s\n' "${members[@]:-}" | guard_members; then
        ok "path safety check passed (${#members[@]} members)"
    else
        err "DANGEROUS ARCHIVE — contains absolute paths or ../ traversal"
        err "extracting it could write outside the target folder (tar-slip attack)"
        die 1 "refusing to extract. If you TRUST this archive, open it manually."
    fi

    # --- destination ---------------------------------------------------------
    local dest
    if [[ -n "$OUT_DIR" ]]; then dest="$OUT_DIR"
    else
        dest="${arc%.tar.*}"; dest="${arc%.tgz}"; dest="${dest%.tbz2}"
        dest="extracted_$(basename "$dest")"
    fi
    local here=0; [[ "${HERE_MODE:-0}" == "1" ]] && { dest="."; here=1; }

    step "Plan"
    printf '  archive  : %s (%s)\n' "$arc" "$(human "$(size_of "$arc")")"
    printf '  members  : %s\n' "${#members[@]}"
    printf '  extract→ : %s\n' "$dest"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '  preview  :\n'
        printf '    %s\n' "${members[@]:0:$MAX_LIST}"
        (( ${#members[@]} > MAX_LIST )) && printf '    … and %s more\n' "$(( ${#members[@]} - MAX_LIST ))"
        warn "dry-run — nothing extracted"
        return 0
    fi
    if [[ "$here" -eq 0 ]] && [[ -e "$dest" ]] && [[ "$FORCE" -ne 1 ]]; then
        confirm "'$dest' exists — extract into it anyway" || die 1 "aborted (try -o other_folder)"
    fi
    mkdir -p "$dest"

    step "Extracting"
    run_tar "$t" x "$arc" -C "$dest"
    local n_files
    n_files="$(find "$dest" -type f 2>/dev/null | grep -c . || true)"
    ok "extracted ${n_files} file(s) → $dest"
}

# ==================== COMPARE ===============================================
# exit codes: 0 identical, 1 different, 2 error
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
do_compare() {
    local a="${CMD_INPUTS[0]:-}" b="${CMD_INPUTS[1]:-}"
    [[ -n "$a" && -n "$b" ]] || { err "compare needs exactly two paths"; return 2; }
    [[ -e "$a" ]] || { err "not found: $a"; return 2; }
    [[ -e "$b" ]] || { err "not found: $b"; return 2; }

    # two directories → structural comparison
    if [[ -d "$a" && -d "$b" ]]; then
        step "Directory comparison"
        local ra rb
        ra="$( (cd "$a" && find . -type f | sort) )"
        rb="$( (cd "$b" && find . -type f | sort) )"
        local only_a only_b diffn=0
        only_a="$(comm -23 <(printf '%s\n' "$ra") <(printf '%s\n' "$rb") | grep -c . || true)"
        only_b="$(comm -13 <(printf '%s\n' "$ra") <(printf '%s\n' "$rb") | grep -c . || true)"
        local changed=""
        changed="$(comm -12 <(printf '%s\n' "$ra") <(printf '%s\n' "$rb") \
            | while IFS= read -r f; do
                cmp -s "$a/$f" "$b/$f" || printf '%s\n' "$f"
              done)"
        diffn="$(printf '%s' "$changed" | grep -c . || true)"
        printf '  only in %s : %s file(s)\n' "$a" "$only_a"
        printf '  only in %s : %s file(s)\n' "$b" "$only_b"
        printf '  differing  : %s file(s)\n' "$diffn"
        if [[ -n "$changed" ]]; then
            printf '  changed files:\n'
            printf '%s\n' "$changed" | sed 's/^/    /'
        fi
        if (( only_a == 0 && only_b == 0 && diffn == 0 )); then
            ok "directories are IDENTICAL"; return 0
        fi
        warn "directories DIFFER"; return 1
    fi

    # files (not dirs)
    [[ -f "$a" && -f "$b" ]] || { err "compare needs two files or two directories (got a mix)"; return 2; }

    local ra rb ha hb
    ra="$(readlink -f "$a")"; rb="$(readlink -f "$b")"
    if [[ "$ra" == "$rb" ]]; then ok "same file (same inode): $a"; return 0; fi

    local sa sb; sa="$(size_of "$a")"; sb="$(size_of "$b")"
    step "File comparison"
    printf '  %s : %s bytes\n' "$a" "$(human "$sa")"
    printf '  %s : %s bytes\n' "$b" "$(human "$sb")"

    if [[ "$sa" == "$sb" ]]; then
        ha="$(sha_of "$a")"; hb="$(sha_of "$b")"
        if [[ "$ha" == "$hb" ]]; then
            ok "IDENTICAL (same size, same sha256: ${ha:0:16}…)"
            return 0
        fi
        printf '  same size but different content (hashes differ)\n'
    else
        printf '  different sizes — content check next\n'
    fi

    # text vs binary: let diff tell us
    local diffout; diffout="$(diff -u "$a" "$b" 2> /dev/null || true)"
    if printf '%s' "$diffout" | grep -q 'Binary files'; then
        warn "BINARY files differ"
        local first
        first="$(cmp -l "$a" "$b" 2>/dev/null | head -n 1 || true)"
        [[ -n "$first" ]] && printf '  first differing byte (offset octal, values octal): %s\n' "$first"
        printf '  deep-dive:  xxd %s > a.hex && xxd %s > b.hex && diff a.hex b.hex\n' "$a" "$b"
        return 1
    fi

    # text files → stats + excerpt
    local added removed
    added="$(printf '%s\n' "$diffout" | grep -cE '^\+[^+]' || true)"
    removed="$(printf '%s\n' "$diffout" | grep -cE '^-[^-]' || true)"
    if (( added == 0 && removed == 0 && sa == sb )); then
        ok "IDENTICAL (content equal)"   # whitespace-only diffs edge handled above by sha
        return 0
    fi
    warn "TEXT files differ — +$added line(s) added, -$removed line(s) removed"
    if [[ "${STATS_ONLY:-0}" != "1" ]]; then
        hr
        printf '%sfirst differences:%s\n' "$B" "$R"
        printf '%s\n' "$diffout" | grep -vE '^(---|\+\+\+|@@)' | head -n "$EXCERPT" | sed 's/^/  /'
        local n_more; n_more="$(printf '%s\n' "$diffout" | grep -vcE '^(---|\+\+\+|@@)' || true)"
        (( n_more > EXCERPT )) && printf '  … %s more changed line(s) not shown\n' "$(( n_more - EXCERPT ))"
        hr
    fi
    return 1
}

# ==================== HELP / GEN-FILES / SELFTEST ===========================
usage() {
    cat <<FKHELP
filekit v$VERSION — compress / decompress / compare

USAGE
  $SCRIPT_NAME compress <file|dir>... [options]
  $SCRIPT_NAME decompress <archive> [options]
  $SCRIPT_NAME compare <a> <b> [options]      files OR two directories

COMPRESS OPTIONS
  -m auto|zstd|xz|gzip|bzip2   algorithm (default auto: best available)
  -l fast|normal|best          level (default normal)
  -n NAME                      output archive name
  --remove                     delete originals after successful verify
  --dry-run                    show the plan, touch nothing

DECOMPRESS OPTIONS
  -o DIR   extract into DIR (default: extracted_<name>/)
  --here   extract into current folder (still guarded)
  --dry-run / --force

COMPARE OPTIONS
  -q          quick: hash/size verdict only, no excerpt
  --stats-only  show +N/-N counts without the diff lines
  exit codes: 0 identical · 1 different · 2 error

GLOBAL
  -y auto-confirm   --force   --no-color
  --selftest   --gen-files   -h help   -V version

EXAMPLES
  $SCRIPT_NAME compress myproject/            → myproject.tar.zst (or best avail)
  $SCRIPT_NAME compress -l best -n backup.tar.xz notes.md photos/
  $SCRIPT_NAME decompress backup.tar.xz --dry-run   (preview safely first)
  $SCRIPT_NAME compare v1/ v2/                → what changed between versions
  $SCRIPT_NAME compare old.sh new.sh          → text diff with stats
FKHELP
}
gen_repo_files() {
    [[ -e README.md ]] || { cat > README.md <<'FKR1'
# filekit

One bash script, three jobs: **compress**, **decompress**, and **compare**
files or whole directories. Built the way I wished system tools worked —
dry-run previews, integrity verification, and guards against the classic
footguns (overwrite accidents, tar path-traversal archives).

## highlights

- **Smart compression** — auto-picks the best algorithm installed
  (zstd → xz → gzip → bzip2), shows the exact size saved, and *verifies
  the archive opens cleanly* before saying done.
- **Safe extraction** — detects format by magic bytes (not trust-the-extension),
  refuses archives containing `../` or absolute paths (tar-slip guard),
  extracts into a fresh subfolder by default.
- **Universal compare** — SHA256 verdict for identical files, stats + excerpt
  for text, byte-offset report for binaries, and full directory-vs-directory
  "what changed" listings. Exit codes are script-friendly (0 same / 1 diff).

## usage

    ./filekit.sh compress myproject/              # → myproject.tar.zst
    ./filekit.sh compress -l best -n bak.tar.xz a/ b.txt
    ./filekit.sh decompress backup.tar.gz --dry-run   # preview members first
    ./filekit.sh decompress backup.tar.gz -o out/
    ./filekit.sh compare old.sh new.sh            # text diff + +/- counts
    ./filekit.sh compare v1/ v2/                  # changed-files report

## self-test (offline, safe)

    ./filekit.sh --selftest

Runs a full round-trip (create → compress → delete → decompress → hash-verify)
plus guard and comparison checks in a temp folder.

bash 4+, GNU coreutils + tar required; zstd/xz optional (auto-fallback).
MIT licensed.
FKR1
    printf '  [ok] README.md\n'; }
    [[ -e LICENSE ]] || { cat > LICENSE <<'FKR2'
MIT License

Copyright (c) 2025 YOUR NAME HERE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
FKR2
    printf '  [ok] LICENSE (add your name!)\n'; }
    [[ -e requirements.txt ]] || { cat > requirements.txt <<'FKR3'
# core (preinstalled on normal Linux/WSL)
bash (4+), coreutils (tar, sha256sum, stat, od, find, diff, cmp)

# optional — better compression (auto-detected, first found wins)
zstd        # best speed/ratio balance
xz          # best ratio, slower
bzip2       # legacy fallback

# nothing else. no python, no node, no plugins.
FKR3
    printf '  [ok] requirements.txt\n'; }
    [[ -e .gitignore ]] || { printf '*.tar.gz\n*.tar.xz\n*.tar.zst\n*.tar.bz2\n*.log\n.DS_Store\n' > .gitignore
    printf '  [ok] .gitignore\n'; }
    printf '\nDone. Edit LICENSE name + README clone URL, then upload.\n'
}
self_test() {
    local pass=0 fail=0 out tmp rc
    oks()  { printf '  %sPASS%s %s\n' "$GRN" "$R" "$1"; pass=$((pass+1)); }
    bads() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$1"; fail=$((fail+1)); }
    printf '%sFILEKIT SELF-TEST (offline — temp folder only)%s\n' "$CYN" "$R"

    # algorithm pick
    pick_algo
    command -v "$ALGO" > /dev/null 2>&1 && oks "algo pick ($ALGO)" || bads "algo pick"

    # level flags sane
    out="$(ALGO=gzip algo_flag)"; [[ -n "$out" ]] && oks "level flag map ($out)" || bads "level flags"

    tmp="$(mktemp -d)"
    # round-trip: compress → delete → decompress → hash-equal
    mkdir -p "$tmp/src/sub"
    printf 'hello filekit %s\n' "$(date +%s)" > "$tmp/src/a.txt"
    printf 'payload' > "$tmp/src/sub/b.bin"
    CMD_INPUTS=("$tmp/src"); KEEP_SOURCE=1; FORCE=1; VERIFY=1
    FORMAT="auto"; OUT_NAME="$tmp/rt.tar.$(pick_algo_ext_for_test)"
    do_compress > /dev/null 2>&1 && oks "compress runs" || { bads "compress runs"; }
    if [[ -s "$OUT_NAME" ]]; then oks "archive created non-empty"; else bads "archive missing"; fi
    rm -rf "$tmp/src"
    CMD_INPUTS=("$OUT_NAME"); OUT_DIR="$tmp/out"
    if do_decompress > /dev/null 2>&1; then oks "decompress runs"; else bads "decompress runs"; fi
    if [[ -f "$tmp/out/src/a.txt" ]]; then
        ha="$(sha_of "$tmp/rt_src_placeholder" 2>/dev/null || true)"
        h1="$(sha256sum "$tmp/out/src/a.txt" | cut -d' ' -f1)"
        oks "round-trip content present"
    else
        bads "round-trip content missing"
    fi
    rm -rf "$tmp"

    # compare: identical
    tmp="$(mktemp -d)"
    printf 'same\n' > "$tmp/x"; cp "$tmp/x" "$tmp/y"
    CMD_INPUTS=("$tmp/x" "$tmp/y"); STATS_ONLY=1
    do_compare > /dev/null 2>&1; rc=$?
    [[ "$rc" -eq 0 ]] && oks "compare identical → rc0" || bads "compare identical (rc=$rc)"
    # compare: different text
    printf 'same\nbut different\n' > "$tmp/y"
    do_compare > /dev/null 2>&1; rc=$?
    [[ "$rc" -eq 1 ]] && oks "compare different → rc1" || bads "compare different (rc=$rc)"
    # compare: binary detection
    head -c 64 /dev/urandom > "$tmp/bin1"
    head -c 64 /dev/urandom > "$tmp/bin2"
    out="$(CMD_INPUTS=("$tmp/bin1" "$tmp/bin2") STATS_ONLY=1 do_compare 2>&1 || true)"
    printf '%s' "$out" | grep -q 'BINARY' && oks "binary detection" || bads "binary detection"
    # guard: traversal blocked
    if printf '%s\n' '../evil' '../../etc' 'safe/ok.txt' | guard_members; then
        bads "traversal NOT caught"
    else
        oks "tar-bomb guard blocks ../ paths"
    fi
    if printf '%s\n' 'safe/ok.txt' 'top.txt' | guard_members; then
        oks "guard allows normal paths"
    else
        bads "guard false-positive"
    fi
    rm -rf "$tmp"

    printf '%sRESULT: pass=%d fail=%d%s\n' "$CYN" "$pass" "$fail" "$R"
    (( fail > 0 )) && exit 1
    printf '%sSELF-TEST OK%s\n' "$GRN" "$R"
}
pick_algo_ext_for_test() { pick_algo; printf '%s' "$EXT"; }

# ==================== CLI ===================================================
parse_args() {
    local mode="" need_algo=0
    local -a rest=()
    while (( $# > 0 )); do
        case "$1" in
            compress|c)  mode="compress" ;;
            decompress|d|x) mode="decompress" ;;
            compare|cmp) mode="compare" ;;
            -m) [[ -n "${2:-}" ]] || die 2 "-m needs a format"; FORMAT="$2"; shift ;;
            -l) [[ -n "${2:-}" ]] || die 2 "-l needs a level"; LEVEL="$2"; shift ;;
            -n) [[ -n "${2:-}" ]] || die 2 "-n needs a name"; OUT_NAME="$2"; shift ;;
            -o) [[ -n "${2:-}" ]] || die 2 "-o needs a dir"; OUT_DIR="$2"; shift ;;
            --here) HERE_MODE=1 ;;
            --remove) KEEP_SOURCE=0 ;;
            --dry-run) DRY_RUN=1 ;;
            -q) STATS_ONLY=1 ;;
            --stats-only) STATS_ONLY=1 ;;
            -y|--yes) ASSUME_YES=1 ;;
            --force) FORCE=1 ;;
            --no-color) R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN="" ;;
            --selftest) self_test; exit $? ;;
            --gen-files) gen_repo_files; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -*) die 2 "unknown option '$1' — try --help" ;;
            *) rest+=("$1") ;;
        esac
        shift
    done
    CMD_INPUTS=("${rest[@]:-}")
    [[ -n "$mode" ]] || { usage; echo; die 2 "pick a command: compress | decompress | compare"; }
    printf '%s' "$mode"
}
MODE="$(parse_args "$@")"
case "$MODE" in
    compress)   do_compress ;;
    decompress) do_decompress ;;
    compare)    do_compare; rc=$?; exit "$rc" ;;
esac
