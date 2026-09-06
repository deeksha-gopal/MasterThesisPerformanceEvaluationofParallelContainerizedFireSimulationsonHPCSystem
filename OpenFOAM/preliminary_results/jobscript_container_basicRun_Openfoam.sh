# Basic execution of Openfoam-v2406 benchmark Container without any changes made to the tutorial

#!/bin/bash
#SBATCH --job-name=of_container_4core
#SBATCH --output=of_container_%j.out
#SBATCH --error=of_container_%j.err
#SBATCH --time=02:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
##SBATCH --exclusive

set -e
set -o pipefail

IMG="/beegfs/gopal/openfoam/openfoam_v2406.sif"
CASE_IN_IMG="/opt/OpenFOAM/OpenFOAM-v2406/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
CASE="/beegfs/gopal/openfoam/smallPoolFire3D_container_4core_${SLURM_JOB_ID}"

module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

rm -rf "$CASE"
mkdir -p "$CASE"

apptainer exec --bind "$CASE:$CASE" "$IMG" \
    bash -lc "cp -a '$CASE_IN_IMG/.' '$CASE/'"

cat > "$CASE/run_case.sh" <<'EOF'
#!/bin/bash
cd /case

export FOAM_INST_DIR=/opt/OpenFOAM

source /opt/OpenFOAM/OpenFOAM-v2406/etc/bashrc

rm -rf 0 processor*
cp -r 0.orig 0

blockMesh > log.blockMesh 2>&1
checkMesh > log.checkMesh 2>&1

decomposePar -force > log.decompose 2>&1
mpirun -np 4 fireFoam -parallel > log.run 2>&1
EOF

apptainer exec --bind "$CASE:/case" "$IMG" \
    bash /case/run_case.sh

echo "Finished."
