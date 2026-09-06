#!/bin/bash
#SBATCH --job-name=host_PATO
#SBATCH --output=host_PATO_%j.out
#SBATCH --error=host_PATO_%j.err
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

# Fixed filesystem path
PATO_INSTALL_DIR="${BASE_DIR}/pato-3.1"

CONTAINER_IMAGE="/beegfs/gopal/new/pato/pato_image.sif"

PATO_REPOSITORY="https://github.com/nasa/pato.git"

NBUILD="${SLURM_CPUS_PER_TASK:-8}"

BUILD_LOG="${BASE_DIR}/pato31_host_build.log"
VERIFY_LOG="${BASE_DIR}/pato31_host_verify.log"

# Initial information
echo "============================================================"
echo "Host PATO-3.1 build"
echo "============================================================"
echo "Host:                 $(hostname)"
echo "Date:                 $(date)"
echo "SLURM job ID:         ${SLURM_JOB_ID:-not-set}"
echo "CPUs per task:        ${SLURM_CPUS_PER_TASK:-not-set}"
echo "CPUs allocated:       ${SLURM_CPUS_ON_NODE:-not-set}"
echo "Build processes:      ${NBUILD}"
echo "Base directory:       ${BASE_DIR}"
echo "OpenFOAM directory:   ${OPENFOAM_DIR}"
echo "ThirdParty directory: ${THIRDPARTY_DIR}"
echo "PATO directory:       ${PATO_INSTALL_DIR}"
echo "Container image:      ${CONTAINER_IMAGE}"
echo "============================================================"

mkdir -p "$BASE_DIR"

rm -f "$BUILD_LOG"
rm -f "$VERIFY_LOG"

# Loaded OpenFOAM and PATO environment variables
unset FOAM_INST_DIR || true
unset WM_PROJECT_INST_DIR || true
unset WM_PROJECT_DIR || true
unset WM_THIRD_PARTY_DIR || true
unset WM_PROJECT_VERSION || true
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

# PATO environment variable (not the fixed installation path)
unset PATO_DIR || true
unset PATO_SRC || true
unset PATO_LIBBIN || true
unset PATO_APPBIN || true

unset MPP_DIRECTORY || true
unset MPP_INSTALL_DIRECTORY || true
unset MPP_DATA_DIRECTORY || true
unset BUILD_DOCUMENTATION || true

# Load GCC 12.3.0 and OpenMPI 4.1.5
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

# Verify existing OpenFOAM installation
echo
echo "============================================================"
echo "Verifying existing OpenFOAM-7 installation"
echo "============================================================"

if [[ ! -d "$OPENFOAM_DIR" ]]; then
    echo "ERROR: OpenFOAM-7 directory does not exist:"
    echo "$OPENFOAM_DIR"
    exit 10
fi

if [[ ! -f "$OPENFOAM_DIR/etc/bashrc" ]]; then
    echo "ERROR: OpenFOAM bashrc does not exist:"
    echo "$OPENFOAM_DIR/etc/bashrc"
    exit 11
fi

if [[ ! -d "$THIRDPARTY_DIR" ]]; then
    echo "ERROR: ThirdParty-7 directory does not exist:"
    echo "$THIRDPARTY_DIR"
    exit 12
fi

# Verify GCC
echo
echo "============================================================"
echo "Verifying GCC 12.3.0"
echo "============================================================"

for command_name in gcc g++ gfortran
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} is unavailable."
        exit 13
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
        echo "Detected GCC version: $GCC_VERSION"
        exit 14
        ;;
esac

case "$(readlink -f "$(command -v g++)")" in
    /beegfs/Tools/*GCCcore/12.3.0/*|\
    /beegfs/Tools/*GCC/12.3.0/*)
        echo "SUCCESS: EasyBuild GCC 12.3.0 is active."
        ;;
    *)
        echo "ERROR: g++ is not from the expected EasyBuild GCC stack."
        echo "Detected path:"
        readlink -f "$(command -v g++)"
        exit 15
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
        exit 16
    fi

    echo
    echo "${command_name}:"
    command -v "$command_name"
    readlink -f "$(command -v "$command_name")"
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"

echo
echo "MPI version:"
echo "$MPI_VERSION"

case "$MPI_VERSION" in
    *4.1.5*)
        echo "SUCCESS: OpenMPI 4.1.5 is active."
        ;;
    *)
        echo "ERROR: Expected OpenMPI 4.1.5."
        echo "Detected: $MPI_VERSION"
        exit 17
        ;;
esac

case "$(readlink -f "$(command -v mpicxx)")" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0/*)
        echo "SUCCESS: Expected EasyBuild OpenMPI is active."
        ;;
    *)
        echo "ERROR: Unexpected mpicxx path:"
        readlink -f "$(command -v mpicxx)"
        exit 18
        ;;
esac

echo
echo "MPI compiler flags:"
mpicxx --showme:compile

echo
echo "MPI linker flags:"
mpicxx --showme:link

# Verify UCX support
echo
echo "============================================================"
echo "Verifying UCX support"
echo "============================================================"

UCX_CHECK="$(ompi_info --param pml ucx --level 1 2>&1 || true)"

echo "$UCX_CHECK"

if ! grep -q "MCA pml: ucx" <<< "$UCX_CHECK"; then
    echo "ERROR: OpenMPI UCX PML component is unavailable."
    exit 19
fi

echo
echo "OpenMPI transport components:"

ompi_info --param btl all --level 1 2>/dev/null |
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
    echo "This does not invalidate the build."
fi

echo "SUCCESS: Host OpenMPI has UCX support."

# Configure OpenFOAM-7
echo
echo "============================================================"
echo "Configuring OpenFOAM-7 environment"
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
OPENFOAM_BASHRC_RC=$?

set -u
set -e
set -o pipefail

echo "OpenFOAM bashrc return code: $OPENFOAM_BASHRC_RC"

# Reassert required configuration after sourcing.
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

# Verify OpenFOAM environment
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

if [[ "$WM_OPTIONS" != "linux64GccDPInt32Opt" ]]; then
    echo "ERROR: Unexpected WM_OPTIONS:"
    echo "$WM_OPTIONS"
    exit 21
fi

for command_name in wmake blockMesh decomposePar reconstructPar
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} is unavailable."
        exit 22
    fi

    echo "${command_name}: $(command -v "$command_name")"
done

# Verify existing OpenFOAM MPI linkage
PSTREAM_LIBRARY="${FOAM_LIBBIN}/openmpi-system/libPstream.so"

if [[ ! -f "$PSTREAM_LIBRARY" ]]; then
    echo "ERROR: OpenFOAM MPI Pstream library does not exist:"
    echo "$PSTREAM_LIBRARY"
    exit 23
fi

echo
echo "Existing OpenFOAM Pstream library:"
echo "$PSTREAM_LIBRARY"

echo
echo "Existing OpenFOAM Pstream dependencies:"
ldd "$PSTREAM_LIBRARY"

if ldd "$PSTREAM_LIBRARY" | grep -q "not found"; then
    echo "ERROR: Existing OpenFOAM Pstream has unresolved dependencies:"
    ldd "$PSTREAM_LIBRARY" | grep "not found"
    exit 24
fi

OPENFOAM_MPI_LIBRARY="$(
    ldd "$PSTREAM_LIBRARY" |
        awk '/libmpi\.so/ {print $3; exit}'
)"

echo
echo "OpenFOAM resolved MPI library:"
echo "${OPENFOAM_MPI_LIBRARY:-not-found}"

case "${OPENFOAM_MPI_LIBRARY:-}" in
    /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0/*)
        echo "SUCCESS: Existing OpenFOAM-7 uses host OpenMPI 4.1.5."
        ;;
    *)
        echo "ERROR: Existing OpenFOAM-7 uses an unexpected MPI library."
        exit 25
        ;;
esac

# Read PATO revision from the container
echo
echo "============================================================"
echo "Reading PATO revision from the container"
echo "============================================================"

if [[ ! -f "$CONTAINER_IMAGE" ]]; then
    echo "ERROR: Container image does not exist:"
    echo "$CONTAINER_IMAGE"
    exit 26
fi

set +e

PATO_COMMIT="$(
    apptainer exec \
        "$CONTAINER_IMAGE" \
        git -C /opt/pato-3.1 rev-parse HEAD 2>/dev/null
)"

PATO_COMMIT_RC=$?

set -e

if [[ "$PATO_COMMIT_RC" -ne 0 || -z "$PATO_COMMIT" ]]; then
    echo "ERROR: Could not obtain the PATO commit from the container."
    echo "Expected container directory: /opt/pato-3.1"
    exit 27
fi

echo "Container PATO commit: $PATO_COMMIT"

# Remove previous host PATO installation if any
echo
echo "============================================================"
echo "Removing previous host PATO installation"
echo "============================================================"

echo "Removing: $PATO_INSTALL_DIR"
rm -rf "$PATO_INSTALL_DIR"

# Clone PATO
echo
echo "============================================================"
echo "Cloning PATO"
echo "============================================================"

git clone "$PATO_REPOSITORY" "$PATO_INSTALL_DIR"

git -C "$PATO_INSTALL_DIR" checkout --detach "$PATO_COMMIT"

echo
echo "Host PATO revision:"
git -C "$PATO_INSTALL_DIR" log -1 --oneline

if [[ ! -f "$PATO_INSTALL_DIR/Allwmake" ]]; then
    echo "ERROR: PATO Allwmake script does not exist:"
    echo "$PATO_INSTALL_DIR/Allwmake"
    exit 28
fi

if [[ ! -f "$PATO_INSTALL_DIR/bashrc" ]]; then
    echo "ERROR: PATO bashrc does not exist:"
    echo "$PATO_INSTALL_DIR/bashrc"
    exit 29
fi

chmod +x "$PATO_INSTALL_DIR/Allwmake"

# Configure and source PATO before building
echo
echo "============================================================"
echo "Configuring PATO-3.1 environment"
echo "============================================================"

# PATO bashrc requires this exact environment variable name.
export PATO_DIR="$PATO_INSTALL_DIR"
export BUILD_DOCUMENTATION="no"

set +e
set +u
set +o pipefail

source "$PATO_INSTALL_DIR/bashrc"
PATO_BASHRC_RC=$?

set -u
set -e
set -o pipefail

echo "PATO bashrc return code: $PATO_BASHRC_RC"

# Reassert important configuration after sourcing PATO.
export PATO_DIR="$PATO_INSTALL_DIR"
export BUILD_DOCUMENTATION="no"

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

export OMP_NUM_THREADS=1
export MAKEFLAGS="-j${NBUILD}"

# Verify PATO environment before building
echo
echo "PATO environment:"
echo "PATO_INSTALL_DIR=$PATO_INSTALL_DIR"
echo "PATO_DIR=${PATO_DIR:-not-set}"
echo "PATO_SRC=${PATO_SRC:-not-set}"
echo "PATO_LIBBIN=${PATO_LIBBIN:-not-set}"
echo "PATO_APPBIN=${PATO_APPBIN:-not-set}"
echo "MPP_DIRECTORY=${MPP_DIRECTORY:-not-set}"
echo "MPP_INSTALL_DIRECTORY=${MPP_INSTALL_DIRECTORY:-not-set}"
echo "MPP_DATA_DIRECTORY=${MPP_DATA_DIRECTORY:-not-set}"
echo "BUILD_DOCUMENTATION=${BUILD_DOCUMENTATION:-not-set}"
echo "WM_PROJECT_DIR=${WM_PROJECT_DIR:-not-set}"
echo "WM_OPTIONS=${WM_OPTIONS:-not-set}"
echo "WM_MPLIB=${WM_MPLIB:-not-set}"
echo "FOAM_MPI=${FOAM_MPI:-not-set}"
echo "WM_NCOMPPROCS=${WM_NCOMPPROCS:-not-set}"
echo "MAKEFLAGS=${MAKEFLAGS:-not-set}"

if [[ -z "${PATO_DIR:-}" ]]; then
    echo "ERROR: PATO_DIR is unset."
    exit 30
fi

if [[ "$PATO_DIR" != "$PATO_INSTALL_DIR" ]]; then
    echo "ERROR: Unexpected PATO_DIR."
    echo "Expected: $PATO_INSTALL_DIR"
    echo "Detected: $PATO_DIR"
    exit 31
fi

if [[ -z "${MPP_DIRECTORY:-}" ]]; then
    echo "ERROR: MPP_DIRECTORY is unset after sourcing PATO bashrc."
    exit 32
fi

if [[ ! -d "$MPP_DIRECTORY" ]]; then
    echo "ERROR: Mutation++ source directory does not exist:"
    echo "$MPP_DIRECTORY"
    exit 33
fi

if [[ ! -f "$MPP_DIRECTORY/CMakeLists.txt" ]]; then
    echo "ERROR: Mutation++ CMakeLists.txt does not exist:"
    echo "$MPP_DIRECTORY/CMakeLists.txt"
    exit 34
fi

echo
echo "Mutation++ source directory:"
echo "$MPP_DIRECTORY"

echo
echo "Mutation++ CMakeLists.txt:"
ls -l "$MPP_DIRECTORY/CMakeLists.txt"

echo
echo "Compiler and build commands:"

for command_name in \
    gcc \
    g++ \
    gfortran \
    mpicc \
    mpicxx \
    mpifort \
    mpirun \
    cmake \
    make \
    wmake
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} is unavailable."
        exit 35
    fi

    echo "${command_name}: $(command -v "$command_name")"
done

# Clean incomplete Mutation++ build directories
echo
echo "============================================================"
echo "Cleaning incomplete PATO and Mutation++ build files"
echo "============================================================"

if [[ -d "$MPP_DIRECTORY/build" ]]; then
    echo "Removing: $MPP_DIRECTORY/build"
    rm -rf "$MPP_DIRECTORY/build"
fi

if [[ -d "$MPP_DIRECTORY/install" ]]; then
    echo "Removing: $MPP_DIRECTORY/install"
    rm -rf "$MPP_DIRECTORY/install"
fi

# Remove an incorrectly created build directory from an earlier failed run.
if [[ -d "${BASE_DIR}/build" ]]; then
    echo "Removing unexpected directory: ${BASE_DIR}/build"
    rm -rf "${BASE_DIR}/build"
fi

# Build PATO
echo
echo "============================================================"
echo "Building PATO-3.1"
echo "============================================================"
echo "Build started: $(date)"
echo "Build log:     $BUILD_LOG"

cd "$PATO_INSTALL_DIR"

set +e
set +o pipefail

./Allwmake 2>&1 | tee "$BUILD_LOG"
PATO_BUILD_RC="${PIPESTATUS[0]}"

set -o pipefail
set -e

echo
echo "PATO Allwmake return code: $PATO_BUILD_RC"

if [[ "$PATO_BUILD_RC" -ne 0 ]]; then
    echo
    echo "============================================================"
    echo "ERROR: PATO-3.1 build failed"
    echo "Allwmake return code: $PATO_BUILD_RC"
    echo "============================================================"

    echo
    echo "First detected errors:"

    grep -nEi \
        'CMake Error|error:|fatal:|undefined reference|cannot find -l|No rule to make target|Killed|No space left|permission denied|Error [0-9]+' \
        "$BUILD_LOG" |
        head -n 150 || true

    echo
    echo "Last 300 lines of the build log:"

    tail -n 300 "$BUILD_LOG" || true

    exit 40
fi

# Reload OpenFOAM and PATO after build
echo
echo "============================================================"
echo "Reloading OpenFOAM and PATO after build"
echo "============================================================"

set +e
set +u
set +o pipefail

source "$OPENFOAM_DIR/etc/bashrc"
OPENFOAM_RELOAD_RC=$?

export PATO_DIR="$PATO_INSTALL_DIR"
source "$PATO_INSTALL_DIR/bashrc"
PATO_RELOAD_RC=$?

set -u
set -e
set -o pipefail

echo "OpenFOAM reload return code: $OPENFOAM_RELOAD_RC"
echo "PATO reload return code:     $PATO_RELOAD_RC"

# Reassert host configuration.
export PATO_DIR="$PATO_INSTALL_DIR"
export BUILD_DOCUMENTATION="no"

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

export OMP_NUM_THREADS=1

# Verify PATO installation
echo
echo "============================================================"
echo "Verifying PATO-3.1 host installation"
echo "============================================================"

set +e
set +o pipefail

{
    echo "PATO host verification"
    echo "Date: $(date)"
    echo

    echo "Environment:"
    echo "PATO_INSTALL_DIR=$PATO_INSTALL_DIR"
    echo "PATO_DIR=${PATO_DIR:-not-set}"
    echo "PATO_SRC=${PATO_SRC:-not-set}"
    echo "PATO_LIBBIN=${PATO_LIBBIN:-not-set}"
    echo "PATO_APPBIN=${PATO_APPBIN:-not-set}"
    echo "MPP_DIRECTORY=${MPP_DIRECTORY:-not-set}"
    echo "MPP_INSTALL_DIRECTORY=${MPP_INSTALL_DIRECTORY:-not-set}"
    echo "WM_PROJECT_DIR=${WM_PROJECT_DIR:-not-set}"
    echo "WM_OPTIONS=${WM_OPTIONS:-not-set}"
    echo "WM_MPLIB=${WM_MPLIB:-not-set}"
    echo "FOAM_MPI=${FOAM_MPI:-not-set}"
    echo

    for command_name in \
        wmake \
        blockMesh \
        decomposePar \
        reconstructPar \
        PATOx
    do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: $command_name is unavailable."
            exit 50
        fi

        echo "$command_name: $(command -v "$command_name")"
    done

    PATO_EXECUTABLE="$(command -v PATOx)"

    if [[ ! -f "$PATO_EXECUTABLE" ]]; then
        echo "ERROR: PATOx executable does not exist:"
        echo "$PATO_EXECUTABLE"
        exit 51
    fi

    echo
    echo "PATOx executable:"
    echo "$PATO_EXECUTABLE"

    echo
    echo "PATOx file information:"
    file "$PATO_EXECUTABLE" || true

    echo
    echo "PATOx dependencies:"
    ldd "$PATO_EXECUTABLE"

    if ldd "$PATO_EXECUTABLE" 2>/dev/null | grep -q "not found"; then
        echo "ERROR: PATOx has unresolved dependencies:"
        ldd "$PATO_EXECUTABLE" | grep "not found"
        exit 52
    fi

    if [[ ! -f "$PSTREAM_LIBRARY" ]]; then
        echo "ERROR: MPI Pstream library does not exist:"
        echo "$PSTREAM_LIBRARY"
        exit 53
    fi

    echo
    echo "OpenFOAM Pstream library:"
    echo "$PSTREAM_LIBRARY"

    echo
    echo "Pstream dependencies:"
    ldd "$PSTREAM_LIBRARY"

    if ldd "$PSTREAM_LIBRARY" | grep -q "not found"; then
        echo "ERROR: Pstream has unresolved dependencies:"
        ldd "$PSTREAM_LIBRARY" | grep "not found"
        exit 54
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
            echo "SUCCESS: PATO/OpenFOAM uses host OpenMPI 4.1.5."
            ;;
        *)
            echo "ERROR: PATO/OpenFOAM uses an unexpected MPI library."
            exit 55
            ;;
    esac

    echo
    echo "Active compiler and MPI versions:"
    gcc --version | sed -n '1p'
    g++ --version | sed -n '1p'
    gfortran --version | sed -n '1p'
    mpirun --version | sed -n '1p'

    echo
    echo "PATO Git revision:"
    git -C "$PATO_INSTALL_DIR" log -1 --oneline

    echo
    echo "OpenFOAM Git revision:"
    git -C "$OPENFOAM_DIR" log -1 --oneline

    echo
    echo "Testing PATOx startup:"
    PATOx -help 2>&1 | head -n 40 || true

    echo
    echo "SUCCESS: PATO-3.1 host verification completed."
} 2>&1 | tee "$VERIFY_LOG"

VERIFY_RC="${PIPESTATUS[0]}"

set -o pipefail
set -e

if [[ "$VERIFY_RC" -ne 0 ]]; then
    echo
    echo "============================================================"
    echo "ERROR: PATO host verification failed"
    echo "Verification return code: $VERIFY_RC"
    echo "============================================================"
    exit "$VERIFY_RC"
fi

# Completion
echo
echo "============================================================"
echo "PATO-3.1 HOST BUILD COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "PATO directory: $PATO_INSTALL_DIR"
echo "Build log:      $BUILD_LOG"
echo "Verify log:     $VERIFY_LOG"
echo "Finished:       $(date)"
echo "============================================================"

exit 0
