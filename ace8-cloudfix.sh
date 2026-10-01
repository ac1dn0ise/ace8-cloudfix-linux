#!/usr/bin/env bash
#
# ace8-cloudfix.sh
#
# Workaround for a shader compilation bug in Ace Combat 8 (AppID 2288340)
# that manifests on NVIDIA GPUs under Proton. The game's SkyTraceCS
# compute shaders initialize invalid cloud/cirrus ranges to (-1, -1),
# then pack those values into half precision after dividing by 131072.
# The generated SPIR-V applies OpQuantizeToF16 to -1/131072, a half
# subnormal, which underflows to negative zero. The invalid sentinel
# then passes the inclusive range check, produces a zero-length
# raymarch step, and the cloud never renders.
#
# This script rewrites the affected OpQuantizeToF16 into an
# OpCopyObject so the original value reaches the packing instruction
# unchanged. It operates on the SPIR-V dump produced by
# VKD3D_SHADER_DUMP_PATH and emits replacements for
# VKD3D_SHADER_OVERRIDE. No game files, Proton builds, or system
# packages are modified.
#
# Reference: https://github.com/ValveSoftware/Proton/issues/10198
#
# Usage:
#   cd /path/to/your/ace8/prefix
#   /path/to/ace8-cloudfix.sh [command] [dump_dir]
#
#   discover [dump_dir]   Scan the shader dump and build a manifest
#   patch                 Apply the fix to each shader in the manifest
#   verify                Validate the patched shaders
#   all [dump_dir]        Run discover, patch, and verify in sequence
#   help                  Show this message
#
# Requirements:
#   spirv-tools (spirv-dis, spirv-as, spirv-val)
#   Arch / CachyOS / SteamOS:  sudo pacman -S spirv-tools
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

# --- Version -----------------------------------------------------------------

VERSION="1.0"

# --- Configuration -----------------------------------------------------------

# All generated directories anchor to the current working directory.
# Running the script from the game prefix places work and override
# directories alongside drive_c/, which keeps the VKD3D_SHADER_OVERRIDE
# path short and easy to remember. Running from anywhere else is
# equally valid; the user chooses by choosing where to cd.
CALL_DIR="$(pwd)"
WORK_DIR="${CALL_DIR}/ace8-work"
OVERRIDE_DIR="${CALL_DIR}/ace8-overrides"
MANIFEST="${WORK_DIR}/manifest.txt"
DUMP_PATH_FILE="${WORK_DIR}/dump_path.txt"
LOG_FILE="${WORK_DIR}/patch.log"

# Defaults to the conventional dump location relative to the current
# working directory. The README instructs running the script from the
# game prefix, so this resolves to <prefix>/shadercache by default.
DEFAULT_DUMP_DIR="${CALL_DIR}/shadercache"

# The sentinel operand being looked for. This is the literal SPIR-V
# representation of -1/131072, which is the value the shader uses to
# mark invalid cloud ranges before packing them to half precision.
SENTINEL_OPERAND="%float_n7_62939453en06"

# The expected number of shaders to patch, taken from the community
# report. Used as a sanity check, not a hard requirement.
EXPECTED_COUNT=16

# Known-good hashes from the Proton issue thread. When the discovered
# hashes match this set, there is high confidence the patch will work.
KNOWN_HASHES=(
    22fdcb556e490841 38f591d7629df2b6 43b1f2ca42fb23c0 59582be9428f0c60
    713ad0f307870d6c 76d3b0fd2325587f 80f225e283cc4d72 87b42e91ceafed10
    88ad084f83cf8ef9 aaf93c80eebd46d5 aff49440c4c76f41 c652fabba323d136
    e2ace7e3e8dbf87b e6afff4a21f36ae7 f00552bae8b97a19 fcef06642b47c3cd
)

# --- Output helpers ----------------------------------------------------------
#
# All status messages go through radio() / radio_w() so they share the
# same << >> format as the reference material. (Cause you know, Ace
# Combat.) Messages that must not be captured by command substitution
# go to stderr via radio_w().

radio()   { printf '<< %s >>\n' "$*"; }
radio_w() { printf '<< %s >>\n' "$*" >&2; }

die() {
    radio_w "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install spirv-tools)"
}

usage() {
    cat <<EOF
<< Ace Combat 8 Cloud Patcher >>
<< V${VERSION} >>

  Workaround for the SkyTraceCS sentinel bug on NVIDIA + Proton.
  See the script header for the full explanation.

  Usage: $(basename "$0") [command] [dump_dir]

  Commands:
    discover [dump_dir]   Scan the shader dump and build a manifest
    patch                 Apply the fix to each shader in the manifest
    verify                Validate the patched shaders
    all [dump_dir]        Run discover, patch, and verify in sequence
    help                  Show this message

  When dump_dir is omitted, the script prompts for it (or uses the
  default when run non-interactively).

  Default dump dir: $DEFAULT_DUMP_DIR

  Output location:
    Work and override directories are created in the current working
    directory. Running from the game prefix keeps everything together:

      cd /path/to/your/ace8/prefix
      $(basename "$0") all

    This produces:
      ./ace8-work/          scratch, safe to delete
      ./ace8-overrides/     patched shaders for VKD3D_SHADER_OVERRIDE

  Requirements:
    spirv-tools (spirv-dis, spirv-as, spirv-val)
    Arch / CachyOS / SteamOS:  sudo pacman -S spirv-tools

  --- Lutris ---
    After a successful run, add this under the game's
    Configure -> System options -> Environment variables:

      VKD3D_SHADER_OVERRIDE=${OVERRIDE_DIR}

    Remove VKD3D_SHADER_DUMP_PATH from the same list. Otherwise the
    game re-dumps roughly 6 GB on every launch.

  --- Steam ---
    Environment variables go in the game's Launch Options instead:

      Right-click the game -> Properties -> General -> Launch Options.

    To use the overrides, set:

      VKD3D_SHADER_OVERRIDE=${OVERRIDE_DIR} %command%

    Remove VKD3D_SHADER_DUMP_PATH from the launch options at this point.

    Note: On older Steam clients, environment variables sometimes
    failed to apply with the 'FOO=bar %command%' pattern. When they
    don't take effect, prefix the line with 'env --':

      env -- VKD3D_SHADER_OVERRIDE=${OVERRIDE_DIR} %command%
EOF
}

# --- Interactive prompt ------------------------------------------------------

# Echoes the dump directory to use. When stdin is a TTY and no argument
# was given, it prompts the user. Status messages go to stderr so
# command substitution captures only the path itself.
prompt_dump_dir() {
    local default="$DEFAULT_DUMP_DIR"
    local answer=""

    if [[ ! -t 0 ]]; then
        printf '%s\n' "$default"
        return
    fi

    radio "Where are the dumped shaders?" >&2
    radio "Press Enter to use the default, or type a path." >&2
    printf '<< dump dir [%s]: ' "$default" >&2
    read -r answer || answer=""

    if [[ -z "$answer" ]]; then
        printf '%s\n' "$default"
    else
        printf '%s\n' "${answer%/}"
    fi
}

resolve_dump_dir() {
    local arg="${1:-}"
    if [[ -n "$arg" ]]; then
        printf '%s\n' "${arg%/}"
    else
        prompt_dump_dir
    fi
}

# --- Commands ----------------------------------------------------------------

# Scans the shader dump for the sentinel pattern and writes a manifest
# of (hash, result_id) pairs. The manifest is the interface between
# the discover and patch stages; nothing else is carried forward.
#
# The result id is the numeric id of the OpQuantizeToF16 whose operand
# is the -1/131072 sentinel. Every SkyTraceCS variant has exactly one.
cmd_discover() {
    require_cmd spirv-dis

    local dump_dir
    dump_dir="$(resolve_dump_dir "${1:-}")"

    [[ -d "$dump_dir" ]] || die "dump directory not found: $dump_dir"

    if ! compgen -G "$dump_dir/*.spv" >/dev/null; then
        die "no .spv files in $dump_dir"
    fi

    mkdir -p "$WORK_DIR"

    radio "Scanning $dump_dir ..."
    radio "Looking for sentinel operand: $SENTINEL_OPERAND"
    radio "This may take a while."

    : > "$MANIFEST"
    printf '%s\n' "$dump_dir" > "$DUMP_PATH_FILE"

    local count=0
    local f id
    for f in "$dump_dir"/*.spv; do
        id=$(spirv-dis "$f" 2>/dev/null \
            | grep -F "OpQuantizeToF16 %float $SENTINEL_OPERAND" \
            | head -n1 \
            | sed -E 's/^[[:space:]]*%([0-9]+).*/\1/' || true)
        if [[ -n "${id:-}" ]]; then
            printf '%s %s\n' "$(basename "$f" .spv)" "$id" >> "$MANIFEST"
            count=$((count + 1))
        fi
    done

    if [[ ! -s "$MANIFEST" ]]; then
        die "no matching shaders found in $dump_dir"
    fi

    radio "Found $count candidate shader(s)."
    radio "Manifest: $MANIFEST"

    if (( count != EXPECTED_COUNT )); then
        radio_w "Expected $EXPECTED_COUNT, found $count."
        radio_w "This may indicate a different game build."
        radio_w "Review the manifest before patching."
    else
        radio "Count matches the known-good reference."
    fi

    # Cross-checks against the known-good hash list. A full match is
    # strong evidence the patch will work; a partial match means the
    # dump came from a different build and the result is less certain.
    local matches=0 h k found
    while read -r h _; do
        [[ -n "$h" ]] || continue
        found=0
        for k in "${KNOWN_HASHES[@]}"; do
            if [[ "$h" == "$k" ]]; then
                found=1
                break
            fi
        done
        (( found == 1 )) && matches=$((matches + 1))
    done < "$MANIFEST"

    radio "Matched $matches of $EXPECTED_COUNT known-good hashes."
    if (( matches == EXPECTED_COUNT )); then
        radio "All known-good hashes present. Good to patch."
    else
        radio_w "Some hashes differ from the reference set."
        radio_w "The patch may still work; verify the clouds after."
    fi
}

# Applies the shader fix. For each (hash, result_id) pair in the
# manifest, disassembles the original shader, rewrites the target
# OpQuantizeToF16 into an OpCopyObject, reassembles, and writes the
# result to the override directory under the original hash name.
#
# The --target-env vulkan1.1 flag corresponds to SPIR-V 1.3, which is
# the version the original shaders were compiled against. Later
# SPIR-V versions (1.4+) require PushConstant variables to appear in
# the entry point interface list, which these shaders do not have.
# --preserve-numeric-ids keeps the module as close to the original as
# possible so the diff stays small and the module's internal numbering
# does not churn.
cmd_patch() {
    require_cmd spirv-dis
    require_cmd spirv-as

    [[ -s "$MANIFEST" ]] || die "manifest not found or empty: $MANIFEST"
    [[ -f "$DUMP_PATH_FILE" ]] || die "dump path file missing; re-run discover"

    local dump_dir
    dump_dir="$(< "$DUMP_PATH_FILE")"
    [[ -d "$dump_dir" ]] || die "recorded dump dir no longer exists: $dump_dir"

    mkdir -p "$OVERRIDE_DIR"
    rm -f "$OVERRIDE_DIR"/*.spv 2>/dev/null || true
    : > "$LOG_FILE"

    radio "Patching from $MANIFEST ..."

    local tmp_asm
    tmp_asm="$(mktemp --suffix=.spvasm)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_asm'" EXIT

    local patched=0 failed=0 h id src out
    while read -r h id; do
        [[ -n "$h" && -n "$id" ]] || continue

        src="$dump_dir/$h.spv"
        if [[ ! -f "$src" ]]; then
            radio_w "source missing: $src"
            failed=$((failed + 1))
            continue
        fi

        out="$OVERRIDE_DIR/$h.spv"

        # Disassembles to SPIR-V assembly text.
        if ! spirv-dis "$src" -o "$tmp_asm" >> "$LOG_FILE" 2>&1; then
            radio_w "disassembly failed: $h"
            failed=$((failed + 1))
            continue
        fi

        # Rewrites the specific OpQuantizeToF16 to OpCopyObject.
        # The pattern is anchored: only the line where the target id
        # is the result id being assigned gets matched, not any line
        # where the id appears as an operand.
        sed -i -E "s/^([[:space:]]*)%${id}( = )OpQuantizeToF16/\1%${id}\2OpCopyObject/" "$tmp_asm"

        # Confirms the replacement actually happened. If the line did
        # not change, the pattern is wrong for this shader and a file
        # that silently fails to patch anything must not be written.
        if ! grep -qE "^[[:space:]]*%${id} = OpCopyObject" "$tmp_asm"; then
            radio_w "replacement did not apply for $h (id $id)"
            failed=$((failed + 1))
            continue
        fi

        # Reassembles. vulkan1.1 maps to SPIR-V 1.3, matching the
        # original shaders.
        if ! spirv-as "$tmp_asm" -o "$out" \
                --target-env vulkan1.1 \
                --preserve-numeric-ids >> "$LOG_FILE" 2>&1; then
            radio_w "assembly failed: $h"
            failed=$((failed + 1))
            continue
        fi

        # Guards against a silent success with no output.
        if [[ ! -s "$out" ]]; then
            radio_w "no output produced for $h"
            failed=$((failed + 1))
            continue
        fi

        patched=$((patched + 1))
    done < "$MANIFEST"

    radio "Patched $patched shader(s). $failed failure(s)."
    radio "Output: $OVERRIDE_DIR"

    if (( failed > 0 )); then
        radio_w "Some patches failed. Review $LOG_FILE."
        exit 1
    fi
}

# Validates every patched shader with spirv-val. This catches any case
# where the reassembled module is malformed, has the wrong SPIR-V
# version, or has internal inconsistency. A failure here means the
# override directory is not safe to use.
cmd_verify() {
    require_cmd spirv-val

    [[ -d "$OVERRIDE_DIR" ]] || die "override dir not found: $OVERRIDE_DIR"

    if ! compgen -G "$OVERRIDE_DIR/*.spv" >/dev/null; then
        die "no .spv files in $OVERRIDE_DIR; did patch actually write output?"
    fi

    radio "Validating patched shaders ..."

    local ok=0 bad=0 f
    for f in "$OVERRIDE_DIR"/*.spv; do
        [[ -f "$f" ]] || continue
        if spirv-val --target-env vulkan1.3 "$f" >> "$LOG_FILE" 2>&1; then
            ok=$((ok + 1))
        else
            radio_w "validation failed: $(basename "$f")"
            bad=$((bad + 1))
        fi
    done

    radio "Validation: $ok ok, $bad failed."

    if (( bad > 0 )); then
        die "some shaders failed validation; do not use this override dir"
    fi
}

# Runs all three stages in sequence and prints the deployment summary
# for both Lutris and Steam users.
cmd_all() {
    cmd_discover "${1:-}"
    cmd_patch
    cmd_verify

    cat <<EOF

<< Mission Complete >>

  Patched shaders:  $OVERRIDE_DIR
  Manifest:         $MANIFEST
  Log:              $LOG_FILE

  --- Lutris ---
  Add this under Configure -> System options -> Environment variables:

    VKD3D_SHADER_OVERRIDE=$OVERRIDE_DIR

  Remove VKD3D_SHADER_DUMP_PATH from the same list. Otherwise the
  game re-dumps ~6 GB on every launch.

  --- Steam ---
  Add this to Launch Options (right-click the game -> Properties ->
  General -> Launch Options):

    VKD3D_SHADER_OVERRIDE=$OVERRIDE_DIR %command%

  Remove VKD3D_SHADER_DUMP_PATH from the launch options at this point.

  When the variables don't take effect on an older Steam client,
  prefix the line with 'env --':

    env -- VKD3D_SHADER_OVERRIDE=$OVERRIDE_DIR %command%

  --- Verification ---
  Launch the game and load into a mission. If the clouds render below
  the horizon, the patch is working. If not, report back with the log
  at $LOG_FILE.

<< End of transmission >>
EOF
}

# --- Entry point -------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift || true

    case "$cmd" in
        discover)       cmd_discover "${1:-}" ;;
        patch)          cmd_patch ;;
        verify)         cmd_verify ;;
        all)            cmd_all "${1:-}" ;;
        help|-h|--help) usage ;;
        *)
            radio_w "unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
