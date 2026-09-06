#!/bin/bash
#SBATCH --job-name=build_v2406_host
#SBATCH --output=build_v2406_host_%j.out
#SBATCH --error=build_v2406_host_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --exclusive

set -euo pipefail

# USER SETTINGS
BASE_DIR="/beegfs/gopal/new/openfoam/host"
OPENFOAM_VERSION="v2406"
OPENFOAM_DIR="${BASE_DIR}/OpenFOAM-${OPENFOAM_VERSION}"
THIRDPARTY_DIR="${BASE_DIR}/ThirdParty-${OPENFOAM_VERSION}"
LOG_DIR="${BASE_DIR}/logs"
BUILD_LOG="${LOG_DIR}/openfoam-${OPENFOAM_VERSION}-host-build.log"
ERROR_LOG="${LOG_DIR}/openfoam-${OPENFOAM_VERSION}-host-errors.log"
VERIFY_LOG="${LOG_DIR}/openfoam-${OPENFOAM_VERSION}-host-verification.log"

REBUILD_FROM_SCRATCH="no" # "no":Reuse the existing extracted OpenFOAM and ThirdParty source directories. "yes": Delete the existing source directories and download them again.
BUILD_JOBS="${SLURM_CPUS_PER_TASK:-4}"
OPENFOAM_URL="https://dl.openfoam.com/source/${OPENFOAM_VERSION}/OpenFOAM-${OPENFOAM_VERSION}.tgz"
THIRDPARTY_URL="https://dl.openfoam.com/source/${OPENFOAM_VERSION}/ThirdParty-${OPENFOAM_VERSION}.tgz"

# HELPER FUNCTIONS
log()
{
    echo "[$(date '+%F %T')] $*"
}
fail()
{
    echo "ERROR: $*" >&2
    exit 1
}
on_error()
{
    local rc=$?
    local line="${1:-unknown}"
    # Prevent recursive execution of this error handler.
    trap - ERR
    set +e

    echo >&2
    echo "============================================================" >&2
    echo "ERROR: script failed" >&2
    echo "Line:      ${line}" >&2
    echo "Exit code: ${rc}" >&2
    echo "============================================================" >&2

    if [[ -f "${ERROR_LOG:-}" && -s "${ERROR_LOG:-}" ]]; then
        echo "---- Last 100 detected compiler-error lines ----" >&2
        tail -n 100 "$ERROR_LOG" >&2
    fi

    if [[ -f "${BUILD_LOG:-}" && -s "${BUILD_LOG:-}" ]]; then
        echo "---- Last 100 build-log lines ----" >&2
        tail -n 100 "$BUILD_LOG" >&2
    fi

    exit "$rc"
}
trap 'on_error $LINENO' ERR
remove_path_component()
{
    local value="${1:-}"
    local pattern="${2:-}"

    printf '%s' "$value" \
        | tr ':' '\n' \
        | awk -v p="$pattern" 'NF && index($0,p)==0' \
        | paste -sd: -
}
source_openfoam_environment()
{
    local source_rc

    trap - ERR

    set +e
    set +u

    # shellcheck disable=SC1090
    source "$OPENFOAM_DIR/etc/bashrc"

    source_rc=$?

    set -u
    set -e

    trap 'on_error $LINENO' ERR

    if [[ "$source_rc" -ne 0 ]]; then
        fail "OpenFOAM bashrc returned exit code $source_rc"
    fi
}

# INITIAL SETUP
mkdir -p "$BASE_DIR"
mkdir -p "$LOG_DIR"

: > "$BUILD_LOG"
: > "$ERROR_LOG"
: > "$VERIFY_LOG"
log "============================================================"
log "Host OpenFOAM-${OPENFOAM_VERSION} build"
log "============================================================"
log "Host:                $(hostname)"
log "Date:                $(date)"
log "SLURM job ID:        ${SLURM_JOB_ID:-not-running-under-slurm}"
log "Base directory:      $BASE_DIR"
log "OpenFOAM directory:  $OPENFOAM_DIR"
log "ThirdParty directory: $THIRDPARTY_DIR"
log "Compiler jobs:       $BUILD_JOBS"
log "Rebuild from scratch: $REBUILD_FROM_SCRATCH"
log "============================================================"

[[ "$BASE_DIR" == "/beegfs/gopal/new/openfoam/host" ]] || \
    fail "Safety check failed: unexpected BASE_DIR=$BASE_DIR"
cd "$BASE_DIR"

# CLEAR PREVIOUS OPENFOAM ENVIRONMENT
log "Clearing inherited OpenFOAM environment variables"
unset FOAM_INST_DIR || true
unset WM_PROJECT_INST_DIR || true
unset WM_PROJECT || true
unset WM_PROJECT_DIR || true
unset WM_PROJECT_VERSION || true
unset WM_THIRD_PARTY_DIR || true

unset WM_OPTIONS || true
unset WM_COMPILER || true
unset WM_COMPILER_TYPE || true
unset WM_MPLIB || true
unset WM_PRECISION_OPTION || true
unset WM_LABEL_SIZE || true
unset WM_COMPILE_OPTION || true
unset WM_NCOMPPROCS || true

unset FOAM_MPI || true
unset FOAM_APPBIN || true
unset FOAM_LIBBIN || true
unset FOAM_USER_APPBIN || true
unset FOAM_USER_LIBBIN || true
unset FOAM_SRC || true

unset MPI_ARCH_PATH || true
unset FFTW_ARCH_PATH || true
unset SCOTCH_ARCH_PATH || true

unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true
unset LIBRARY_PATH || true
unset PKG_CONFIG_PATH || true

# LOAD THE CLUSTER TOOLCHAIN
log "Loading GCC 12.3.0 and OpenMPI 4.1.5"
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

# Optional modules.
module load CMake 2>/dev/null || true

module load FFTW/3.3.10-GCC-12.3.0 2>/dev/null || \
module load FFTW/3.3.10-gompi-2023a 2>/dev/null || \
module load FFTW 2>/dev/null || true

echo
echo "Loaded modules:"
module list 2>&1 || true
echo

# VERIFY GCC
log "Verifying GCC compiler"
for compiler_command in gcc g++ gfortran
do
    if ! command -v "$compiler_command" >/dev/null 2>&1; then
        fail "$compiler_command is unavailable"
    fi

    echo "$compiler_command:"
    command -v "$compiler_command"
    readlink -f "$(command -v "$compiler_command")"
    "$compiler_command" --version | sed -n '1p'
    echo
done

GCC_VERSION="$(gcc -dumpfullversion -dumpversion)"

case "$GCC_VERSION" in
    12.3.0*)
        log "GCC 12.3.0 detected"
        ;;
    *)
        fail "Expected GCC 12.3.0, but detected $GCC_VERSION"
        ;;
esac
case "$(readlink -f "$(command -v g++)")" in
    /beegfs/Tools/*GCCcore/12.3.0/*|\
    /beegfs/Tools/*GCC/12.3.0/*)
        log "Expected EasyBuild GCC 12.3.0 is active"
        ;;
    *)
        echo "Resolved g++ path:" >&2
        readlink -f "$(command -v g++)" >&2
        fail "g++ is not from the expected EasyBuild GCC 12.3.0 stack"
        ;;
esac

# VERIFY OPENMPI
log "Verifying OpenMPI"
for mpi_command in mpicc mpicxx mpifort mpirun ompi_info
do
    if ! command -v "$mpi_command" >/dev/null 2>&1; then
        fail "$mpi_command is unavailable"
    fi

    echo "$mpi_command:"
    command -v "$mpi_command"
    readlink -f "$(command -v "$mpi_command")"
    echo
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"

echo "MPI version:"
echo "$MPI_VERSION"
echo

case "$MPI_VERSION" in
    *4.1.5*)
        log "OpenMPI 4.1.5 detected"
        ;;
    *)
        fail "Expected OpenMPI 4.1.5, but detected: $MPI_VERSION"
        ;;
esac

case "$(readlink -f "$(command -v mpicxx)")" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0/*)
        log "Expected EasyBuild OpenMPI 4.1.5 is active"
        ;;
    *)
        echo "Resolved mpicxx path:" >&2
        readlink -f "$(command -v mpicxx)" >&2
        fail "mpicxx is not from OpenMPI 4.1.5-GCC-12.3.0"
        ;;
esac

echo "MPI compiler flags:"
mpicxx --showme:compile
echo

echo "MPI linker flags:"
mpicxx --showme:link
echo

# DETERMINE OPENMPI PREFIX
MPI_PREFIX="$(
    ompi_info --path prefix --parsable 2>/dev/null |
    awk -F: '$2=="prefix" {print $3; exit}'
)"

if [[ -z "$MPI_PREFIX" ]]; then
    MPI_PREFIX="$(
        dirname "$(
            dirname "$(
                readlink -f "$(command -v mpicc)"
            )"
        )"
    )"
fi

[[ -n "$MPI_PREFIX" ]] || \
    fail "Could not determine OpenMPI prefix"

[[ -d "$MPI_PREFIX" ]] || \
    fail "OpenMPI prefix does not exist: $MPI_PREFIX"

export MPI_ARCH_PATH="$MPI_PREFIX"

log "OpenMPI prefix: $MPI_ARCH_PATH"

# VERIFY UCX COMPONENT AVAILABILITY
log "Verifying that OpenMPI exposes the UCX PML component"

UCX_CHECK="$(
    ompi_info --param pml ucx --level 1 2>&1 || true
)"

echo "$UCX_CHECK" | tee -a "$VERIFY_LOG"

if ! grep -qi 'MCA pml: ucx' <<< "$UCX_CHECK"; then
    fail "OpenMPI 4.1.5 does not expose the UCX PML component"
fi

{
    echo
    echo "===== OpenMPI/UCX information ====="
    ompi_info --param pml ucx --level 9 || true

    echo
    echo "===== OpenMPI configuration ====="
    ompi_info --config || true

    echo
    echo "===== UCX transports and devices ====="

    if command -v ucx_info >/dev/null 2>&1; then
        ucx_info -d || true
    else
        echo "ucx_info is not available in PATH"
    fi

    echo
    echo "===== InfiniBand devices ====="

    if command -v ibv_devinfo >/dev/null 2>&1; then
        ibv_devinfo || true
    else
        echo "ibv_devinfo is not available in PATH"
        echo "This does not invalidate the OpenFOAM build."
    fi
} >> "$VERIFY_LOG" 2>&1

log "OpenMPI UCX component is available"

# FIND FFTW
log "Locating FFTW installation"

FFTW_PREFIX="${EBROOTFFTW:-}"

if [[ -z "$FFTW_PREFIX" ]]; then
    FFTW_HEADER="$(
        find /beegfs/Tools/easybuild/stacks/rome/2023a_AL9/software \
            -path '*/include/fftw3.h' \
            -print \
            -quit \
            2>/dev/null || true
    )"

    if [[ -n "$FFTW_HEADER" ]]; then
        FFTW_PREFIX="$(dirname "$(dirname "$FFTW_HEADER")")"
    fi
fi

[[ -n "$FFTW_PREFIX" ]] || \
    fail "Could not determine FFTW prefix"

[[ -d "$FFTW_PREFIX" ]] || \
    fail "FFTW prefix does not exist: $FFTW_PREFIX"

[[ -f "$FFTW_PREFIX/include/fftw3.h" ]] || \
    fail "FFTW header is missing: $FFTW_PREFIX/include/fftw3.h"

export FFTW_ARCH_PATH="$FFTW_PREFIX"

log "FFTW prefix: $FFTW_ARCH_PATH"

# PREPARE FFTW PATHS
export PATH="$(
    remove_path_component "${PATH:-}" '/FFTW/'
)"
export PATH="$FFTW_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$(
    remove_path_component "${LD_LIBRARY_PATH:-}" '/FFTW/'
)"
if [[ -d "$FFTW_PREFIX/lib64" ]]; then
    export LD_LIBRARY_PATH="$FFTW_PREFIX/lib64:${LD_LIBRARY_PATH:-}"
elif [[ -d "$FFTW_PREFIX/lib" ]]; then
    export LD_LIBRARY_PATH="$FFTW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
else
    fail "No FFTW lib or lib64 directory found under $FFTW_PREFIX"
fi

# I have not added /usr/include through these variables becuase doing so can break GCC's include_next handling.
unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true

# GCC INCLUDE SANITY TEST
log "Running GCC include-path sanity test"

cat > "$BASE_DIR/gcc_include_test.cpp" <<'CPP'
#include <stdlib.h>
#include <iostream>

int main()
{
    std::cout << "gcc include test passed\n";
    return 0;
}
CPP

g++ \
    "$BASE_DIR/gcc_include_test.cpp" \
    -o "$BASE_DIR/gcc_include_test"

"$BASE_DIR/gcc_include_test"

rm -f "$BASE_DIR/gcc_include_test.cpp"
rm -f "$BASE_DIR/gcc_include_test"

# DOWNLOAD OR REUSE OPENFOAM SOURCES
cd "$BASE_DIR"

if [[ "$REBUILD_FROM_SCRATCH" == "yes" ]]; then
    log "Removing existing OpenFOAM and ThirdParty source directories"

    rm -rf "$OPENFOAM_DIR"
    rm -rf "$THIRDPARTY_DIR"
fi


if [[ -d "$OPENFOAM_DIR" ]]; then
    log "Reusing existing OpenFOAM source directory:"
    log "$OPENFOAM_DIR"
else
    log "Downloading OpenFOAM-${OPENFOAM_VERSION}"

    rm -f "OpenFOAM-${OPENFOAM_VERSION}.tgz"

    wget \
        --tries=3 \
        --timeout=60 \
        -O "OpenFOAM-${OPENFOAM_VERSION}.tgz" \
        "$OPENFOAM_URL"

    tar -xzf "OpenFOAM-${OPENFOAM_VERSION}.tgz"

    rm -f "OpenFOAM-${OPENFOAM_VERSION}.tgz"
fi


if [[ -d "$THIRDPARTY_DIR" ]]; then
    log "Reusing existing ThirdParty source directory:"
    log "$THIRDPARTY_DIR"
else
    log "Downloading ThirdParty-${OPENFOAM_VERSION}"

    rm -f "ThirdParty-${OPENFOAM_VERSION}.tgz"

    wget \
        --tries=3 \
        --timeout=60 \
        -O "ThirdParty-${OPENFOAM_VERSION}.tgz" \
        "$THIRDPARTY_URL"

    tar -xzf "ThirdParty-${OPENFOAM_VERSION}.tgz"

    rm -f "ThirdParty-${OPENFOAM_VERSION}.tgz"
fi

# VERIFY SOURCE DIRECTORIES
[[ -d "$OPENFOAM_DIR" ]] || \
    fail "OpenFOAM directory is missing: $OPENFOAM_DIR"

[[ -f "$OPENFOAM_DIR/etc/bashrc" ]] || \
    fail "OpenFOAM bashrc is missing: $OPENFOAM_DIR/etc/bashrc"

[[ -f "$OPENFOAM_DIR/Allwmake" ]] || \
    fail "OpenFOAM Allwmake is missing: $OPENFOAM_DIR/Allwmake"

[[ -d "$THIRDPARTY_DIR" ]] || \
    fail "ThirdParty directory is missing: $THIRDPARTY_DIR"

# CONFIGURE OPENFOAM
log "Configuring OpenFOAM for system GCC and system OpenMPI"

export FOAM_INST_DIR="$BASE_DIR"
export WM_PROJECT_INST_DIR="$BASE_DIR"

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI

export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export MPI_ARCH_PATH
export FFTW_ARCH_PATH
export WM_NCOMPPROCS="$BUILD_JOBS"

# CONFIGURE SYSTEM FFTW
FFTW_CONFIG="$OPENFOAM_DIR/etc/config.sh/FFTW"

if [[ -f "$FFTW_CONFIG" ]]; then
    log "Configuring OpenFOAM FFTW file: $FFTW_CONFIG"

    python3 - "$FFTW_CONFIG" "$FFTW_ARCH_PATH" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
prefix = sys.argv[2]

text = path.read_text()

text = re.sub(
    r"(?m)^\s*fftw_version=.*$",
    "fftw_version=fftw-system",
    text,
)

text = re.sub(
    r"(?m)^\s*export\s+FFTW_ARCH_PATH=.*$",
    f"export FFTW_ARCH_PATH={prefix}",
    text,
)

if "export FFTW_ARCH_PATH=" not in text:
    text += f"\nexport FFTW_ARCH_PATH={prefix}\n"

path.write_text(text)
PY
else
    log "NOTE: $FFTW_CONFIG does not exist"
    log "FFTW_ARCH_PATH will still be provided through the environment"
fi

# REMOVE OLD BUILD PRODUCTS
# OpenFOAM-v2406 does not contain a top-level ./Allwclean. Remove only generated platform binaries and libraries.
if [[ "$REBUILD_FROM_SCRATCH" != "yes" ]]; then
    log "Removing old platform build products"

    rm -rf "$OPENFOAM_DIR/platforms"
fi

# SOURCE OPENFOAM ENVIRONMENT
unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true

source_openfoam_environment

# REASSERT REQUIRED SETTINGS
export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI

export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export MPI_ARCH_PATH
export FFTW_ARCH_PATH
export WM_NCOMPPROCS="$BUILD_JOBS"

# DISPLAY AND VERIFY OPENFOAM ENVIRONMENT
log "OpenFOAM environment"

echo "WM_PROJECT=${WM_PROJECT:-}"
echo "WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}"
echo "WM_PROJECT_DIR=${WM_PROJECT_DIR:-}"
echo "WM_THIRD_PARTY_DIR=${WM_THIRD_PARTY_DIR:-}"
echo "WM_OPTIONS=${WM_OPTIONS:-}"
echo "WM_COMPILER_TYPE=${WM_COMPILER_TYPE:-}"
echo "WM_COMPILER=${WM_COMPILER:-}"
echo "WM_MPLIB=${WM_MPLIB:-}"
echo "FOAM_MPI=${FOAM_MPI:-}"
echo "MPI_ARCH_PATH=${MPI_ARCH_PATH:-}"
echo "FFTW_ARCH_PATH=${FFTW_ARCH_PATH:-}"
echo "WM_NCOMPPROCS=${WM_NCOMPPROCS:-}"

[[ "${WM_PROJECT_VERSION:-}" == "$OPENFOAM_VERSION" ]] || \
    fail "Unexpected WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-not-set}"

[[ "${WM_OPTIONS:-}" == "linux64GccDPInt32Opt" ]] || \
    fail "Unexpected WM_OPTIONS=${WM_OPTIONS:-not-set}"

[[ "${WM_COMPILER_TYPE:-}" == "system" ]] || \
    fail "Unexpected WM_COMPILER_TYPE=${WM_COMPILER_TYPE:-not-set}"

[[ "${WM_COMPILER:-}" == "Gcc" ]] || \
    fail "Unexpected WM_COMPILER=${WM_COMPILER:-not-set}"

[[ "${WM_MPLIB:-}" == "SYSTEMOPENMPI" ]] || \
    fail "Unexpected WM_MPLIB=${WM_MPLIB:-not-set}"

[[ "${FOAM_MPI:-}" == "sys-openmpi" ]] || \
    fail "Unexpected FOAM_MPI=${FOAM_MPI:-not-set}"

# VERIFY COMPILERS AFTER SOURCING OPENFOAM
case "$(readlink -f "$(command -v g++)")" in
    /beegfs/Tools/*GCCcore/12.3.0/*|\
    /beegfs/Tools/*GCC/12.3.0/*)
        log "OpenFOAM will use EasyBuild GCC 12.3.0"
        ;;
    *)
        echo "Resolved g++ path:" >&2
        readlink -f "$(command -v g++)" >&2
        fail "OpenFOAM would use an unexpected C++ compiler"
        ;;
esac

case "$(readlink -f "$(command -v mpicxx)")" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0/*)
        log "OpenFOAM will use EasyBuild OpenMPI 4.1.5"
        ;;
    *)
        echo "Resolved mpicxx path:" >&2
        readlink -f "$(command -v mpicxx)" >&2
        fail "OpenFOAM would use an unexpected MPI compiler"
        ;;
esac

# BUILD OPENFOAM
log "Building OpenFOAM-${OPENFOAM_VERSION}"
log "Build log: $BUILD_LOG"

cd "$OPENFOAM_DIR"

set +e
set +o pipefail

./Allwmake -j "$BUILD_JOBS" \
    2>&1 | tee -a "$BUILD_LOG"

BUILD_RC="${PIPESTATUS[0]}"

set -o pipefail
set -e

log "OpenFOAM Allwmake exit code: $BUILD_RC"

ERROR_PATTERN='fatal error:|error:|undefined reference|cannot find -l|No rule to make target|No such file or directory|collect2:|wmake.*error|make(\[[0-9]+\])?: \*\*\*|Killed|No space left|permission denied|cannot allocate memory|out of memory'

{
    echo "OpenFOAM-${OPENFOAM_VERSION} detected build errors"
    echo "Build return code: $BUILD_RC"
    echo "Build log: $BUILD_LOG"
    echo

    grep \
        -nEi \
        -A20 \
        -B20 \
        "$ERROR_PATTERN" \
        "$BUILD_LOG" || true
} > "$ERROR_LOG"

if [[ "$BUILD_RC" -ne 0 ]]; then
    fail "OpenFOAM build failed with return code $BUILD_RC; see $BUILD_LOG"
fi

log "OpenFOAM compilation completed successfully"

# SOURCE THE COMPLETED OPENFOAM INSTALLATION
unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true

source_openfoam_environment

# Reassert the selected external package locations.
export MPI_ARCH_PATH="$MPI_PREFIX"
export FFTW_ARCH_PATH="$FFTW_PREFIX"

# FINAL ENVIRONMENT VERIFICATION
{
    echo "============================================================"
    echo "OpenFOAM-${OPENFOAM_VERSION} host build verification"
    echo "============================================================"
    echo "Date: $(date)"
    echo "Host: $(hostname)"
    echo
    echo "WM_PROJECT=${WM_PROJECT:-}"
    echo "WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}"
    echo "WM_PROJECT_DIR=${WM_PROJECT_DIR:-}"
    echo "WM_THIRD_PARTY_DIR=${WM_THIRD_PARTY_DIR:-}"
    echo "WM_OPTIONS=${WM_OPTIONS:-}"
    echo "WM_COMPILER_TYPE=${WM_COMPILER_TYPE:-}"
    echo "WM_COMPILER=${WM_COMPILER:-}"
    echo "WM_MPLIB=${WM_MPLIB:-}"
    echo "FOAM_MPI=${FOAM_MPI:-}"
    echo "MPI_ARCH_PATH=${MPI_ARCH_PATH:-}"
    echo "FFTW_ARCH_PATH=${FFTW_ARCH_PATH:-}"
    echo
    echo "===== GCC version ====="
    gcc --version | sed -n '1p'
    echo
    echo "===== OpenMPI version ====="
    mpirun --version | sed -n '1p'
    echo
} | tee -a "$VERIFY_LOG"

# VERIFY REQUIRED OPENFOAM EXECUTABLES
log "Verifying required OpenFOAM executables"

for executable in \
    wmake \
    blockMesh \
    checkMesh \
    decomposePar \
    reconstructPar \
    fireFoam
do
    executable_path="$(command -v "$executable" || true)"

    echo "${executable}: ${executable_path}" | tee -a "$VERIFY_LOG"

    if [[ -z "$executable_path" ]]; then
        fail "$executable is not available in PATH"
    fi

    if [[ ! -x "$executable_path" ]]; then
        fail "$executable exists but is not executable: $executable_path"
    fi
done

# VERIFY PSTREAM LIBRARY
PSTREAM_LIB="$FOAM_LIBBIN/sys-openmpi/libPstream.so"

[[ -f "$PSTREAM_LIB" ]] || \
    fail "OpenFOAM Pstream library is missing: $PSTREAM_LIB"

# RECORD SHARED-LIBRARY LINKAGE
{
    echo
    echo "===== libPstream MPI linkage ====="
    ldd "$PSTREAM_LIB"

    echo
    echo "===== fireFoam linkage ====="
    ldd "$(command -v fireFoam)"

    echo
    echo "===== FFTW linkage ====="

    if [[ -f "$FOAM_LIBBIN/librandomProcesses.so" ]]; then
        ldd "$FOAM_LIBBIN/librandomProcesses.so"
    else
        echo "librandomProcesses.so is missing"
    fi
} >> "$VERIFY_LOG" 2>&1

# VERIFY OPENMPI LINKAGE
MPI_LINK="$(
    ldd "$PSTREAM_LIB" |
    grep -E 'libmpi\.so' |
    head -n 1 || true
)"

echo "OpenFOAM MPI link: $MPI_LINK" | tee -a "$VERIFY_LOG"

if [[ -z "$MPI_LINK" ]]; then
    fail "libPstream.so is not linked to libmpi.so"
fi

if [[ "$MPI_LINK" != *"OpenMPI/4.1.5-GCC-12.3.0"* ]]; then
    fail "libPstream.so is not linked to OpenMPI 4.1.5-GCC-12.3.0"
fi

log "OpenFOAM is linked to OpenMPI 4.1.5-GCC-12.3.0"

# CHECK FOR MISSING FIREFOAM LIBRARIES
MISSING_FIREFOAM_LIBS="$(
    ldd "$(command -v fireFoam)" |
    grep 'not found' || true
)"

if [[ -n "$MISSING_FIREFOAM_LIBS" ]]; then
    echo "$MISSING_FIREFOAM_LIBS" >&2
    fail "fireFoam has missing shared libraries"
fi

log "fireFoam has no missing shared libraries"

# VERIFY FFTW LINKAGE
RANDOM_PROCESSES_LIB="$FOAM_LIBBIN/librandomProcesses.so"

[[ -f "$RANDOM_PROCESSES_LIB" ]] || \
    fail "Missing FFTW-dependent library: $RANDOM_PROCESSES_LIB"

FFTW_LINK="$(
    ldd "$RANDOM_PROCESSES_LIB" |
    grep -E 'libfftw3\.so' |
    head -n 1 || true
)"

echo "OpenFOAM FFTW link: $FFTW_LINK" | tee -a "$VERIFY_LOG"

if [[ -z "$FFTW_LINK" ]]; then
    fail "librandomProcesses.so is not linked to FFTW"
fi

if [[ "$FFTW_LINK" != *"$FFTW_PREFIX"* ]]; then
    fail "librandomProcesses.so is not linked to the selected FFTW installation"
fi

log "OpenFOAM is linked to FFTW at $FFTW_PREFIX"

# VERIFY UCX COMPONENT AFTER BUILD
UCX_FINAL_CHECK="$(
    ompi_info --param pml ucx --level 1 2>&1 || true
)"

echo >> "$VERIFY_LOG"
echo "===== Final OpenMPI UCX component check =====" >> "$VERIFY_LOG"
echo "$UCX_FINAL_CHECK" >> "$VERIFY_LOG"

if ! grep -qi 'MCA pml: ucx' <<< "$UCX_FINAL_CHECK"; then
    fail "UCX PML component is unavailable after the build"
fi

log "OpenMPI UCX PML component remains available"

# BUILD SUMMARY
{
    echo
    echo "============================================================"
    echo "FINAL RESULT: SUCCESS"
    echo "============================================================"
    echo "OpenFOAM version:     ${OPENFOAM_VERSION}"
    echo "OpenFOAM directory:   ${OPENFOAM_DIR}"
    echo "Compiler:             GCC 12.3.0"
    echo "MPI:                  OpenMPI 4.1.5"
    echo "OpenFOAM MPI type:    ${FOAM_MPI:-}"
    echo "OpenFOAM build type:  ${WM_OPTIONS:-}"
    echo "MPI library:          ${MPI_LINK}"
    echo "FFTW library:         ${FFTW_LINK}"
    echo
    echo "============================================================"
} | tee -a "$VERIFY_LOG"


log "Host OpenFOAM-${OPENFOAM_VERSION} build completed successfully"
log "Installation:     $OPENFOAM_DIR"
log "Build log:        $BUILD_LOG"
log "Error scan log:   $ERROR_LOG"
log "Verification log: $VERIFY_LOG"

exit 0
