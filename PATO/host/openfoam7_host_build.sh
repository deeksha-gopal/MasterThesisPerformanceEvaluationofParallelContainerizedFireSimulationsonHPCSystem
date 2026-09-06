#!/bin/bash
#SBATCH --job-name=host_OF7
#SBATCH --output=host_OF7_%j.out
#SBATCH --error=host_OF7_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --exclusive

set -euo pipefail

# Configuration
BASE_DIR="/beegfs/gopal/new/pato/host"
FOAM_BASE="${BASE_DIR}/OpenFOAM"

OPENFOAM_DIR="${FOAM_BASE}/OpenFOAM-7"
THIRDPARTY_DIR="${FOAM_BASE}/ThirdParty-7"

CONTAINER_IMAGE="/beegfs/gopal/new/pato/pato_image.sif"

NBUILD="${SLURM_CPUS_PER_TASK:-8}"

OPENFOAM_REPOSITORY="https://github.com/OpenFOAM/OpenFOAM-7.git"
THIRDPARTY_REPOSITORY="https://github.com/OpenFOAM/ThirdParty-7.git"

BUILD_LOG="${BASE_DIR}/openfoam7_host_build.log"
VERIFY_LOG="${BASE_DIR}/openfoam7_host_verify.log"

# Initial information
echo "============================================================"
echo "Host OpenFOAM-7 build"
echo "============================================================"
echo "Host:             $(hostname)"
echo "Date:             $(date)"
echo "Job ID:           ${SLURM_JOB_ID:-not-set}"
echo "Build processes:  ${NBUILD}"
echo "Installation:     ${FOAM_BASE}"
echo "Container image:  ${CONTAINER_IMAGE}"
echo "============================================================"

mkdir -p "$BASE_DIR"
mkdir -p "$FOAM_BASE"

rm -f "$BUILD_LOG" "$VERIFY_LOG"
  
# Load OpenFOAM variables
unset FOAM_INST_DIR || true
unset WM_PROJECT_INST_DIR || true
unset WM_PROJECT_DIR || true
unset WM_THIRD_PARTY_DIR || true
unset WM_PROJECT_VERSION || true
unset WM_OPTIONS || true
unset WM_COMPILER || true
unset WM_COMPILER_TYPE || true
unset WM_MPLIB || true
unset FOAM_MPI || true
unset FOAM_APPBIN || true
unset FOAM_LIBBIN || true
unset FOAM_USER_APPBIN || true
unset FOAM_USER_LIBBIN || true
unset FOAM_SRC || true

# Load the same host tools used by the container
echo
echo "============================================================"
echo "Loading GCC 12.3.0 and OpenMPI 4.1.5"
echo "============================================================"

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

module load M4 2>/dev/null || \
module load gm4 2>/dev/null || true

echo
echo "Loaded modules:"
module list 2>&1 || true

# Verify compiler
echo
echo "============================================================"
echo "Verifying GCC"
echo "============================================================"

for command_name in gcc g++ gfortran
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} is unavailable."
        exit 10
    fi

    echo
    echo "${command_name}:"
    command -v "$command_name"
    readlink -f "$(command -v "$command_name")"
    "$command_name" --version | sed -n '1p'
done

GCC_VERSION="$(gcc -dumpfullversion)"

case "$GCC_VERSION" in
    12.3.0*)
        echo "SUCCESS: GCC 12.3.0 is active."
        ;;
    *)
        echo "ERROR: Expected GCC 12.3.0."
        echo "Detected: $GCC_VERSION"
        exit 11
        ;;
esac

case "$(readlink -f "$(command -v g++)")" in
    /beegfs/Tools/*GCCcore/12.3.0/*|\
    /beegfs/Tools/*GCC/12.3.0/*)
        echo "SUCCESS: EasyBuild GCC 12.3.0 is active."
        ;;
    *)
        echo "ERROR: g++ is not from the expected EasyBuild GCC stack."
        readlink -f "$(command -v g++)"
        exit 12
        ;;
esac

# Verify OpenMPI
echo
echo "============================================================"
echo "Verifying OpenMPI 4.1.5"
echo "============================================================"

for command_name in mpicc mpicxx mpifort mpirun ompi_info
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} is unavailable."
        exit 13
    fi

    echo
    echo "${command_name}:"
    command -v "$command_name"
    readlink -f "$(command -v "$command_name")"
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"

echo
echo "$MPI_VERSION"

case "$MPI_VERSION" in
    *4.1.5*)
        echo "SUCCESS: OpenMPI 4.1.5 is active."
        ;;
    *)
        echo "ERROR: Expected OpenMPI 4.1.5."
        echo "Detected: $MPI_VERSION"
        exit 14
        ;;
esac

case "$(readlink -f "$(command -v mpicxx)")" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0/*)
        echo "SUCCESS: Expected EasyBuild OpenMPI is active."
        ;;
    *)
        echo "ERROR: Unexpected mpicxx path:"
        readlink -f "$(command -v mpicxx)"
        exit 15
        ;;
esac

echo
echo "MPI compiler flags:"
mpicxx --showme:compile

echo
echo "MPI linker flags:"
mpicxx --showme:link

# Verify UCX and InfiniBand-related MPI support
echo
echo "============================================================"
echo "Verifying UCX and InfiniBand support"
echo "============================================================"

UCX_CHECK="$(ompi_info --param pml ucx --level 1 2>&1 || true)"
echo "$UCX_CHECK"

if ! grep -q "MCA pml: ucx" <<< "$UCX_CHECK"; then
    echo "ERROR: OpenMPI UCX PML component is unavailable."
    exit 16
fi

echo
echo "OpenMPI transport components:"
ompi_info --param btl all --level 1 2>/dev/null | \
    grep -E 'MCA btl: (openib|uct|self|vader|tcp)' || true

echo
echo "OpenMPI UCX component:"
ompi_info --param pml ucx --level 9 || true

if command -v ucx_info >/dev/null 2>&1; then
    echo
    echo "UCX version:"
    ucx_info -v || true
fi

if command -v ibv_devinfo >/dev/null 2>&1; then
    echo
    echo "InfiniBand devices visible on this node:"
    ibv_devinfo -l || true
else
    echo
    echo "NOTE: ibv_devinfo is unavailable."
    echo "This does not invalidate the MPI build."
fi

echo "SUCCESS: Host OpenMPI has UCX support."

# Get exact source revisions from the container
echo
echo "============================================================"
echo "Reading source revisions from the PATO container"
echo "============================================================"

if [[ ! -f "$CONTAINER_IMAGE" ]]; then
    echo "ERROR: Container image not found:"
    echo "$CONTAINER_IMAGE"
    exit 17
fi

OPENFOAM_COMMIT="$(
    apptainer exec \
        "$CONTAINER_IMAGE" \
        git -C /opt/OpenFOAM/OpenFOAM-7 rev-parse HEAD
)"

THIRDPARTY_COMMIT="$(
    apptainer exec \
        "$CONTAINER_IMAGE" \
        git -C /opt/OpenFOAM/ThirdParty-7 rev-parse HEAD
)"

echo "Container OpenFOAM commit:   $OPENFOAM_COMMIT"
echo "Container ThirdParty commit: $THIRDPARTY_COMMIT"

if [[ -z "$OPENFOAM_COMMIT" || -z "$THIRDPARTY_COMMIT" ]]; then
    echo "ERROR: Could not determine container source revisions."
    exit 18
fi

# Remove old host build
echo
echo "============================================================"
echo "Removing old host OpenFOAM build"
echo "============================================================"

rm -rf "$OPENFOAM_DIR"
rm -rf "$THIRDPARTY_DIR"

# Clone the OpenFOAM and ThirdParty
echo
echo "============================================================"
echo "Cloning OpenFOAM-7"
echo "============================================================"

git clone "$OPENFOAM_REPOSITORY" "$OPENFOAM_DIR"

git -C "$OPENFOAM_DIR" checkout --detach "$OPENFOAM_COMMIT"

echo
echo "Host OpenFOAM revision:"
git -C "$OPENFOAM_DIR" log -1 --oneline

echo
echo "============================================================"
echo "Cloning ThirdParty-7"
echo "============================================================"

git clone "$THIRDPARTY_REPOSITORY" "$THIRDPARTY_DIR"

git -C "$THIRDPARTY_DIR" checkout --detach "$THIRDPARTY_COMMIT"

echo
echo "Host ThirdParty revision:"
git -C "$THIRDPARTY_DIR" log -1 --oneline

# Configure OpenFOAM environment
echo
echo "============================================================"
echo "Configuring OpenFOAM-7"
echo "============================================================"

export FOAM_INST_DIR="$FOAM_BASE"
export WM_PROJECT_INST_DIR="$FOAM_BASE"
export WM_PROJECT_DIR="$OPENFOAM_DIR"
export WM_THIRD_PARTY_DIR="$THIRDPARTY_DIR"

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt
export WM_NCOMPPROCS="$NBUILD"

set +e
set +u
set +o pipefail

source "$OPENFOAM_DIR/etc/bashrc"
SOURCE_RC=$?

set -u
set -e
set -o pipefail

echo "OpenFOAM bashrc return code: $SOURCE_RC"

# Reassert the required configuration.
export FOAM_INST_DIR="$FOAM_BASE"
export WM_PROJECT_INST_DIR="$FOAM_BASE"
export WM_PROJECT_DIR="$OPENFOAM_DIR"
export WM_THIRD_PARTY_DIR="$THIRDPARTY_DIR"

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt
export WM_NCOMPPROCS="$NBUILD"

# Verify the environment
echo
echo "OpenFOAM environment:"
echo "FOAM_INST_DIR=$FOAM_INST_DIR"
echo "WM_PROJECT_INST_DIR=$WM_PROJECT_INST_DIR"
echo "WM_PROJECT_DIR=$WM_PROJECT_DIR"
echo "WM_THIRD_PARTY_DIR=$WM_THIRD_PARTY_DIR"
echo "WM_COMPILER_TYPE=$WM_COMPILER_TYPE"
echo "WM_COMPILER=$WM_COMPILER"
echo "WM_MPLIB=$WM_MPLIB"
echo "WM_OPTIONS=${WM_OPTIONS:-not-set}"
echo "FOAM_MPI=${FOAM_MPI:-not-set}"
echo "FOAM_APPBIN=${FOAM_APPBIN:-not-set}"
echo "FOAM_LIBBIN=${FOAM_LIBBIN:-not-set}"

if [[ -z "${WM_OPTIONS:-}" ]]; then
    echo "ERROR: WM_OPTIONS is unset."
    exit 20
fi

if [[ "${WM_OPTIONS}" != "linux64GccDPInt32Opt" ]]; then
    echo "ERROR: Unexpected WM_OPTIONS:"
    echo "$WM_OPTIONS"
    exit 21
fi

if ! command -v wmake >/dev/null 2>&1; then
    echo "ERROR: wmake is unavailable."
    exit 22
fi

echo
echo "Compiler paths used for the host build:"
command -v gcc
command -v g++
command -v mpicc
command -v mpicxx
command -v mpirun
command -v wmake

# Build OpenFOAM-7
echo
echo "============================================================"
echo "Building OpenFOAM-7 using ${NBUILD} processes"
echo "============================================================"

cd "$OPENFOAM_DIR"

set +e
set +o pipefail

./Allwmake -j "$NBUILD" 2>&1 | tee "$BUILD_LOG"
OPENFOAM_BUILD_RC="${PIPESTATUS[0]}"

set -o pipefail
set -e

if [[ "$OPENFOAM_BUILD_RC" -ne 0 ]]; then
    echo
    echo "============================================================"
    echo "ERROR: OpenFOAM-7 build failed"
    echo "Allwmake return code: $OPENFOAM_BUILD_RC"
    echo "============================================================"

    echo
    echo "First detected errors:"
    grep -nEi \
        'error:|fatal:|undefined reference|cannot find -l|No rule to make target|Killed|No space left|permission denied|Error [0-9]+' \
        "$BUILD_LOG" |
        head -n 100 || true

    echo
    echo "Last 300 lines:"
    tail -n 300 "$BUILD_LOG" || true

    exit 30
fi

# Reload and verify OpenFOAM
set +e
set +u
set +o pipefail

source "$OPENFOAM_DIR/etc/bashrc"

set -u
set -e
set -o pipefail

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

{
    echo "OpenFOAM host verification"
    echo "Date: $(date)"
    echo

    for command_name in \
        wmake \
        blockMesh \
        decomposePar \
        reconstructPar
    do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: $command_name is unavailable."
            exit 40
        fi

        echo "$command_name: $(command -v "$command_name")"
    done

    echo
    echo "WM_OPTIONS=$WM_OPTIONS"
    echo "FOAM_MPI=${FOAM_MPI:-not-set}"

    PSTREAM_LIBRARY="${FOAM_LIBBIN}/openmpi-system/libPstream.so"

    if [[ ! -f "$PSTREAM_LIBRARY" ]]; then
        echo "ERROR: MPI Pstream library does not exist:"
        echo "$PSTREAM_LIBRARY"
        exit 41
    fi

    echo
    echo "Pstream library:"
    echo "$PSTREAM_LIBRARY"

    echo
    echo "Pstream dependencies:"
    ldd "$PSTREAM_LIBRARY"

    if ldd "$PSTREAM_LIBRARY" | grep -q "not found"; then
        echo "ERROR: Pstream has unresolved dependencies."
        ldd "$PSTREAM_LIBRARY" | grep "not found"
        exit 42
    fi

    MPI_LIBRARY="$(
        ldd "$PSTREAM_LIBRARY" |
        awk '/libmpi\.so/ {print $3; exit}'
    )"

    echo
    echo "Resolved MPI library:"
    echo "${MPI_LIBRARY:-not-found}"

    case "${MPI_LIBRARY:-}" in
        /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0/*)
            echo "SUCCESS: OpenFOAM uses host OpenMPI 4.1.5."
            ;;
        *)
            echo "ERROR: OpenFOAM uses an unexpected MPI library."
            exit 43
            ;;
    esac
} 2>&1 | tee "$VERIFY_LOG"

echo
echo "============================================================"
echo "Host OpenFOAM-7 build completed successfully"
echo "============================================================"
echo "Build log:  $BUILD_LOG"
echo "Verify log: $VERIFY_LOG"
echo "Finished:   $(date)"
