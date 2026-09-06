# Basic execution of Openfoam-v2406 benchmark Host without any changes made to the tutorial

#!/bin/bash
#SBATCH --job-name=of_host_4core
#SBATCH --output=of_host_%j.out
#SBATCH --error=of_host_%j.err
#SBATCH --time=02:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
##SBATCH --exclusive

set -e
set -o pipefail

OPENFOAM_DIR="/beegfs/gopal/openfoam/host/OpenFOAM-v2406"
FOAM_INST_DIR="/beegfs/gopal/openfoam/host"

SRC_CASE="/beegfs/gopal/openfoam/host/OpenFOAM-v2406/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
CASE="/beegfs/gopal/openfoam/host/smallPoolFire3D_host_4core_${SLURM_JOB_ID}"

module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

export FOAM_INST_DIR="$FOAM_INST_DIR"
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

set +u
set +e
source "$OPENFOAM_DIR/etc/bashrc"
SRC_RC=$?
set -e
set -u

rm -rf "$CASE"
mkdir -p "$CASE"
cp -a "$SRC_CASE/." "$CASE/"
cd "$CASE"

rm -rf 0 processor*
cp -r 0.orig 0

blockMesh > log.blockMesh 2>&1
checkMesh > log.checkMesh 2>&1

decomposePar -force > log.decompose 2>&1
mpirun -np 4 fireFoam -parallel > log.run 2>&1

echo "Finished."
