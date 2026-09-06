# This code shows the execution of the openfoam-7 initially 

#!/bin/bash
#SBATCH --job-name=install_OF7
#SBATCH --output=install_OF7_%j.out
#SBATCH --error=install_OF7_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1

set -e
set -o pipefail

BASE_DIR="/beegfs/gopal/pato/host"
FOAM_BASE="${BASE_DIR}/OpenFOAM"
NBUILD=8

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Install dir: $FOAM_BASE"

mkdir -p "$FOAM_BASE"
cd "$FOAM_BASE"

echo "==> Loading modules"
module purge
module load 2022a
module load gompi/2022a CMake
module load M4 2>/dev/null || module load gm4 2>/dev/null || true

echo "==> Modules loaded"
module list 2>&1 || true

if [ ! -d "OpenFOAM-7" ] || [ ! -d "ThirdParty-7" ]; then
    echo "==> Downloading and unpacking OpenFOAM-7 sources"
    rm -rf OpenFOAM-7-version-7 ThirdParty-7-version-7

    wget -O - http://dl.openfoam.org/source/7 | tar xvz
    wget -O - http://dl.openfoam.org/third-party/7 | tar xvz

    [ -d "OpenFOAM-7-version-7" ] || { echo "ERROR: OpenFOAM-7-version-7 not found after unpack"; exit 1; }
    [ -d "ThirdParty-7-version-7" ] || { echo "ERROR: ThirdParty-7-version-7 not found after unpack"; exit 1; }

    rm -rf OpenFOAM-7 ThirdParty-7
    mv OpenFOAM-7-version-7 OpenFOAM-7
    mv ThirdParty-7-version-7 ThirdParty-7
else
    echo "==> OpenFOAM-7 and ThirdParty-7 already present, skipping download"
fi

echo "==> Directory check"
ls -ld "$FOAM_BASE/OpenFOAM-7" "$FOAM_BASE/ThirdParty-7"

cd "$FOAM_BASE/OpenFOAM-7"

# Important for source builds
export WM_PROJECT_INST_DIR="$FOAM_BASE"
export FOAM_INST_DIR="$FOAM_BASE"

echo "==> Sourcing OpenFOAM-7"
set +e
source "$FOAM_BASE/OpenFOAM-7/etc/bashrc"
SRC_RC=$?
set -e

echo "==> source rc = $SRC_RC"
if [ "$SRC_RC" -ne 0 ]; then
    echo "ERROR: sourcing OpenFOAM-7 bashrc failed"
    exit 2
fi

echo "==> Environment after sourcing"
echo "WM_PROJECT_INST_DIR=$WM_PROJECT_INST_DIR"
echo "WM_PROJECT_DIR=$WM_PROJECT_DIR"
echo "WM_THIRD_PARTY_DIR=$WM_THIRD_PARTY_DIR"
echo "FOAM_INST_DIR=$FOAM_INST_DIR"

echo "==> Starting compilation"
./Allwmake -j "${NBUILD}" 2>&1 | tee build.log

echo "==> Verifying installation"
set +e
source "$FOAM_BASE/OpenFOAM-7/etc/bashrc"
SRC2_RC=$?
set -e

echo "==> second source rc = $SRC2_RC"
which blockMesh || { echo "ERROR: blockMesh not found"; exit 3; }
which decomposePar || { echo "ERROR: decomposePar not found"; exit 4; }

echo "==> SUCCESS: OpenFOAM-7 installed correctly"
echo "==> Finished at $(date)"
