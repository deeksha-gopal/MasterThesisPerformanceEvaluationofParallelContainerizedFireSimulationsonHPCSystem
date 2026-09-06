# This is the jobscript to install Host Openfoam_v2406

#!/bin/bash
#SBATCH --job-name=install_openfoam_v2406_host
#SBATCH --output=install_openfoam_v2406_%j.out
#SBATCH --error=install_openfoam_v2406_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4

set -o pipefail

BASE_DIR="/beegfs/gopal/openfoam/host"
OPENFOAM_DIR="${BASE_DIR}/OpenFOAM-v2406"
THIRDPARTY_DIR="${BASE_DIR}/ThirdParty-v2406"
BUILD_LOG="${BASE_DIR}/openfoam_v2406_build.log"

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Base dir: $BASE_DIR"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR" || exit 1

echo "==> Loading modules"
module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

module load FFTW 2>/dev/null || \
module load FFTW/3.3.10-GCC-12.3.0 2>/dev/null || \
module load FFTW/3.3.10-gompi-2023a 2>/dev/null || true

FFTW_LIB="$(find /beegfs/Tools/easybuild/stacks/rome/2023a_AL9/software -name 'libfftw3.so.3*' 2>/dev/null | head -n 1 || true)"

if [ -n "$FFTW_LIB" ]; then
    FFTW_LIB_DIR="$(dirname "$FFTW_LIB")"
    export LD_LIBRARY_PATH="${FFTW_LIB_DIR}:${LD_LIBRARY_PATH:-}"
    echo "==> FFTW lib dir: $FFTW_LIB_DIR"
else
    echo "WARNING: FFTW library not found"
fi

if [ ! -d "$OPENFOAM_DIR" ]; then
    echo "==> Downloading OpenFOAM-v2406"
    wget -O OpenFOAM-v2406.tgz "https://sourceforge.net/projects/openfoam/files/v2406/OpenFOAM-v2406.tgz/download" || exit 2
    tar -xzf OpenFOAM-v2406.tgz || exit 3
    rm -f OpenFOAM-v2406.tgz
else
    echo "==> OpenFOAM-v2406 already exists"
fi

if [ ! -d "$THIRDPARTY_DIR" ]; then
    echo "==> Downloading ThirdParty-v2406"
    wget -O ThirdParty-v2406.tgz "https://sourceforge.net/projects/openfoam/files/v2406/ThirdParty-v2406.tgz/download" || exit 4
    tar -xzf ThirdParty-v2406.tgz || exit 5
    rm -f ThirdParty-v2406.tgz
else
    echo "==> ThirdParty-v2406 already exists"
fi

echo "==> Setting OpenFOAM environment"

export FOAM_INST_DIR="$BASE_DIR"
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI

unset WM_PROJECT_DIR
unset WM_THIRD_PARTY_DIR
unset WM_PROJECT_VERSION

set +u
source "$OPENFOAM_DIR/etc/bashrc"
SRC_RC=$?
set -u

echo "==> Source return code: $SRC_RC"

if [ "$SRC_RC" -ne 0 ]; then
    echo "ERROR: OpenFOAM bashrc failed"
    exit 6
fi

echo "==> Environment check"
echo "WM_PROJECT_DIR=${WM_PROJECT_DIR:-}"
echo "WM_THIRD_PARTY_DIR=${WM_THIRD_PARTY_DIR:-}"
echo "WM_OPTIONS=${WM_OPTIONS:-}"
echo "WM_COMPILER=${WM_COMPILER:-}"
echo "WM_MPLIB=${WM_MPLIB:-}"

FIREFOAM_BIN="${OPENFOAM_DIR}/platforms/linux64GccDPInt32Opt/bin/fireFoam"

if [ -x "$FIREFOAM_BIN" ]; then
    echo "==> fireFoam already exists, skipping rebuild"
else
    echo "==> Building OpenFOAM-v2406"
    echo "==> Build log: $BUILD_LOG"

    cd "$OPENFOAM_DIR" || exit 7
    ./Allwmake -j "$SLURM_CPUS_PER_TASK" 2>&1 | tee -a "$BUILD_LOG"
    BUILD_RC=${PIPESTATUS[0]}

    echo "==> Build return code: $BUILD_RC"

    if [ "$BUILD_RC" -ne 0 ]; then
        echo "ERROR: Build failed"
        tail -n 100 "$BUILD_LOG"
        exit 8
    fi
fi

echo "==> Final verification"

set +u
source "$OPENFOAM_DIR/etc/bashrc"
SRC2_RC=$?
set -u

if [ "$SRC2_RC" -ne 0 ]; then
    echo "ERROR: second source failed"
    exit 9
fi

BLOCKMESH="$(command -v blockMesh || true)"
CHECKMESH="$(command -v checkMesh || true)"
DECOMPOSEPAR="$(command -v decomposePar || true)"
FIREFOAM="$(command -v fireFoam || true)"

echo "blockMesh:    $BLOCKMESH"
echo "checkMesh:    $CHECKMESH"
echo "decomposePar: $DECOMPOSEPAR"
echo "fireFoam:     $FIREFOAM"

if [ ! -x "$BLOCKMESH" ]; then echo "ERROR: blockMesh missing"; exit 10; fi
if [ ! -x "$CHECKMESH" ]; then echo "ERROR: checkMesh missing"; exit 11; fi
if [ ! -x "$DECOMPOSEPAR" ]; then echo "ERROR: decomposePar missing"; exit 12; fi
if [ ! -x "$FIREFOAM" ]; then echo "ERROR: fireFoam missing"; exit 13; fi

echo "==> Testing fireFoam"
fireFoam -help | head -n 5

echo "SUCCESS: OpenFOAM-v2406 host installation is complete"
echo "==> Finished at $(date)"

exit 0
