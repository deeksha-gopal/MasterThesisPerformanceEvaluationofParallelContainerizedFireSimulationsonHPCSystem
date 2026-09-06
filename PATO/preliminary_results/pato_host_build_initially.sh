#!/bin/bash
#SBATCH --job-name=install_pato
#SBATCH --output=install_pato_%j.out
#SBATCH --error=install_pato_%j.err
#SBATCH --time=12:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1

set -e
set -o pipefail

BASE_DIR="/beegfs/gopal/pato/host"
FOAM_DIR="${BASE_DIR}/OpenFOAM"
PATO_DIR="${BASE_DIR}/pato-3.1"
TMP_EXTRACT_DIR="${BASE_DIR}/pato_extract_tmp"

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Base dir: $BASE_DIR"
echo "==> FOAM_DIR: $FOAM_DIR"
echo "==> PATO_DIR: $PATO_DIR"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo "==> Loading modules"
module purge
module load 2022a
module load gompi/2022a CMake
module load M4 2>/dev/null || module load gm4 2>/dev/null || true
module list 2>&1 || true

if [ ! -d "$FOAM_DIR/OpenFOAM-7" ]; then
    echo "ERROR: OpenFOAM-7 not found at $FOAM_DIR/OpenFOAM-7"
    exit 1
fi

if [ ! -d "$PATO_DIR" ]; then
    echo "==> Downloading PATO-3.1"
    rm -f pato.tar.gz
    rm -rf "$TMP_EXTRACT_DIR"
    mkdir -p "$TMP_EXTRACT_DIR"

    wget https://github.com/nasa/pato/archive/refs/tags/3.1.tar.gz -O pato.tar.gz \
      || wget https://github.com/nasa/pato/archive/refs/tags/v3.1.tar.gz -O pato.tar.gz

    echo "==> Extracting PATO archive into temp directory"
    tar -xzf pato.tar.gz -C "$TMP_EXTRACT_DIR"

    echo "==> Contents of temp extract dir"
    ls -la "$TMP_EXTRACT_DIR"

    EXTRACTED_DIR="$(find "$TMP_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$EXTRACTED_DIR" ]; then
        echo "ERROR: could not find extracted PATO directory"
        exit 1
    fi

    echo "==> Extracted directory: $EXTRACTED_DIR"
    rm -rf "$PATO_DIR"
    mv "$EXTRACTED_DIR" "$PATO_DIR"
    rm -rf "$TMP_EXTRACT_DIR"
else
    echo "==> PATO already exists at $PATO_DIR, skipping download"
fi

echo "==> Sourcing OpenFOAM"
export FOAM_INST_DIR="$FOAM_DIR"
export WM_MPLIB=SYSTEMOPENMPI
export WM_COMPILER=Gcc

set +e
source "$FOAM_DIR/OpenFOAM-7/etc/bashrc"
SRC_RC=$?
set -e

echo "==> OpenFOAM source rc: $SRC_RC"
if [ "$SRC_RC" -ne 0 ]; then
    echo "ERROR: failed to source OpenFOAM"
    exit 2
fi

echo "==> OpenFOAM environment check"
echo "WM_PROJECT_DIR=$WM_PROJECT_DIR"
echo "WM_THIRD_PARTY_DIR=$WM_THIRD_PARTY_DIR"
echo "which wmake: $(command -v wmake || true)"
echo "which blockMesh: $(command -v blockMesh || true)"
echo "which mpicc: $(command -v mpicc || true)"
echo "which mpirun: $(command -v mpirun || true)"

echo "==> Sourcing PATO"
export PATO_DIR="$PATO_DIR"

set +e
source "$PATO_DIR/bashrc"
PATO_SRC_RC=$?
set -e

echo "==> PATO source rc: $PATO_SRC_RC"
if [ "$PATO_SRC_RC" -ne 0 ]; then
    echo "ERROR: failed to source PATO bashrc"
    exit 3
fi

cd "$PATO_DIR"

if [ ! -x "$PATO_DIR/install/bin/PATOx" ]; then
    echo "==> Building PATO"
    ./AllwcleanAllclean || true
    ./Allwmake -j 8 2>&1 | tee build.log
else
    echo "==> PATO already built, skipping build"
fi

SOLVER="$PATO_DIR/install/bin/PATOx"
if [ -x "$SOLVER" ]; then
    echo "SUCCESS: PATO installed correctly"
    echo "Solver: $SOLVER"
else
    echo "ERROR: PATO build failed"
    exit 4
fi

echo "==> Finished at $(date)"
