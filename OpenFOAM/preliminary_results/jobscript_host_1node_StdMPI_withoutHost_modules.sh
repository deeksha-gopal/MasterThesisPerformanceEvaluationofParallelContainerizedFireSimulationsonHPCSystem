# This code is the initial preliminary results of running Openfoam-V2406 Host without same OpenMPI and GCC modules as Host/HPC cluster. 
# Where Host and Container had different modules unlike the final results. 

#!/bin/bash
#SBATCH --job-name=openfoam_host_fixedIter
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

SRC_CASE="/beegfs/gopal/openfoam/host/OpenFOAM-v2406/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
WORK_CASE="/beegfs/gopal/openfoam/host/smallPoolFire3D_host_fixedIter_hierarchical_mesh120_${SLURM_JOB_ID}"
LOGS="${WORK_CASE}/logs"

OPENFOAM_DIR="/beegfs/gopal/openfoam/host/OpenFOAM-v2406"
FOAM_INST_DIR="/beegfs/gopal/openfoam/host"

PROCS_LIST="${PROCS_LIST:-2 4 6 8 10 12 16 20 32 36 40 42 44 48 50}"
MPI_FLAGS="${MPI_FLAGS:---oversubscribe}"

rm -rf "$WORK_CASE"
mkdir -p "$LOGS"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Source case: $SRC_CASE"
echo "==> Work case: $WORK_CASE"
echo "==> Processor list: $PROCS_LIST"
echo "==> Method: hierarchical"

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

export FOAM_INST_DIR="$FOAM_INST_DIR"
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

SOURCE_LOG="${LOGS}/source_openfoam.log"

echo "==> Sourcing OpenFOAM"

set +e
set +u
source "${OPENFOAM_DIR}/etc/bashrc" > "$SOURCE_LOG" 2>&1
SRC_RC=$?
set -u
set -e

echo "==> Source return code: $SRC_RC"

if [ "$SRC_RC" -ne 0 ]; then
    echo "ERROR: OpenFOAM bashrc failed"
    tail -n 100 "$SOURCE_LOG" || true
    exit 1
fi

echo "==> Environment check"
echo "blockMesh:    $(command -v blockMesh || true)"
echo "checkMesh:    $(command -v checkMesh || true)"
echo "decomposePar: $(command -v decomposePar || true)"
echo "fireFoam:     $(command -v fireFoam || true)"
echo "mpirun:       $(command -v mpirun || true)"

if ! command -v blockMesh >/dev/null 2>&1; then echo "ERROR: blockMesh not found"; exit 2; fi
if ! command -v checkMesh >/dev/null 2>&1; then echo "ERROR: checkMesh not found"; exit 3; fi
if ! command -v decomposePar >/dev/null 2>&1; then echo "ERROR: decomposePar not found"; exit 4; fi
if ! command -v fireFoam >/dev/null 2>&1; then echo "ERROR: fireFoam not found"; exit 5; fi

echo "==> Copying tutorial case"
cp -a "${SRC_CASE}/." "$WORK_CASE/"

echo "==> Updating mesh to 80x80x80"
sed -i 's/(60[[:space:]]\+60[[:space:]]\+60)/(120 120 120)/' "$WORK_CASE/system/blockMeshDict"

echo "==> Updating controlDict"
sed -i 's/^[[:space:]]*deltaT[[:space:]].*/deltaT          0.00075;/' "$WORK_CASE/system/controlDict"
sed -i 's/^[[:space:]]*maxCo[[:space:]].*/maxCo           0.45;/' "$WORK_CASE/system/controlDict"
sed -i 's/^[[:space:]]*adjustTimeStep[[:space:]].*/adjustTimeStep  no;/' "$WORK_CASE/system/controlDict"
sed -i 's/^[[:space:]]*endTime[[:space:]].*/endTime         0.075;/' "$WORK_CASE/system/controlDict"
sed -i 's/^[[:space:]]*writeControl[[:space:]].*/writeControl    timeStep;/' "$WORK_CASE/system/controlDict"
sed -i 's/^[[:space:]]*writeInterval[[:space:]].*/writeInterval   100;/' "$WORK_CASE/system/controlDict"

echo "==> Removing old functions block"
sed -i '/^functions[[:space:]]*$/,$d' "$WORK_CASE/system/controlDict"

echo "==> Adding timeInfo and solverInfo"
cat >> "$WORK_CASE/system/controlDict" <<'EOF'

functions
{
    time
    {
        type            timeInfo;
        libs            (utilityFunctionObjects);

        writeControl    timeStep;
        writeInterval   1;

        writeToFile     yes;
        perTimeStep     yes;
    }

    solverInfo
    {
        type            solverInfo;
        libs            (utilityFunctionObjects);

        writeControl    timeStep;
        writeInterval   1;

        fields          (ph_rgh p_rgh U h O2 CH4 CO2 H2O k);
    }
}
EOF

echo "==> Rewriting fvSolution with fixed iteration controls"
cat > "$WORK_CASE/system/fvSolution" <<'EOF'
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      fvSolution;
}

solvers
{
    "(rho|rhoFinal)"
    {
        solver              PCG;
        preconditioner      DIC;
        tolerance           1e-6;
        relTol              0;

        minIter             0;
        maxIter             0;
    };

    p_rgh
    {
        solver              GAMG;
        tolerance           1e-6;
        relTol              0.1;
        smoother            GaussSeidel;

        minIter             2;
        maxIter             2;
    };

    p_rghFinal
    {
        $p_rgh;
        tolerance           1e-6;
        relTol              0;

        minIter             2;
        maxIter             2;
    };

    ph_rgh
    {
        $p_rgh;

        minIter             2;
        maxIter             2;
    }

    "(U|Yi|k|h)"
    {
        solver          PBiCGStab;
        preconditioner  DILU;
        tolerance       1e-6;
        relTol          0.1;
        nSweeps         1;

        minIter         1;
        maxIter         1;
    };

    "(U|Yi|k|h)Final"
    {
        $U;
        tolerance       1e-6;
        relTol          0;

        minIter         1;
        maxIter         1;
    };

    Ii
    {
        solver              GAMG;
        tolerance           1e-4;
        relTol              0;
        smoother            symGaussSeidel;

        minIter             1;
        maxIter             1;
        nPostSweeps         1;
    }

    G
    {
        solver          PCG;
        preconditioner  DIC;
        tolerance       1e-04;
        relTol          0;

        minIter         1;
        maxIter         1;
    }
}

PIMPLE
{
    momentumPredictor yes;
    nOuterCorrectors  1;
    nCorrectors       2;
    nNonOrthogonalCorrectors 0;

    hydrostaticInitialization yes;
    nHydrostaticCorrectors 5;
}

relaxationFactors
{
    equations
    {
        "(U|k).*"                   1;
        "(CH4|O2|H2O|CO2|h).*"      1;
    }
}
EOF

echo "==> Confirming edits"
grep -n "80 80 80" "$WORK_CASE/system/blockMeshDict" || true
grep -E "deltaT|maxCo|adjustTimeStep|endTime|writeControl|writeInterval" "$WORK_CASE/system/controlDict" || true
grep -n "timeInfo\|solverInfo" "$WORK_CASE/system/controlDict" || true
grep -n "minIter\|maxIter\|tolerance\|relTol" "$WORK_CASE/system/fvSolution" || true

cd "$WORK_CASE"

echo "==> One-time mesh preparation"
rm -rf 0
cp -r 0.orig 0
rm -rf constant/polyMesh

echo "==> blockMesh"
blockMesh > "$LOGS/log.blockMesh" 2> "$LOGS/err.blockMesh"

echo "==> checkMesh"
checkMesh > "$LOGS/log.checkMesh" 2> "$LOGS/err.checkMesh"

echo "==> Starting processor sweep with hierarchical decomposition"

for N in $PROCS_LIST; do
    echo "==== N=$N ===="

    case "$N" in
        2)  NX=2; NY=1; NZ=1 ;;
        4)  NX=2; NY=2; NZ=1 ;;
        6)  NX=3; NY=2; NZ=1 ;;
        8)  NX=2; NY=2; NZ=2 ;;
        10) NX=5; NY=2; NZ=1 ;;
        12) NX=3; NY=2; NZ=2 ;;
        16) NX=4; NY=2; NZ=2 ;;
        20) NX=5; NY=2; NZ=2 ;;
        32) NX=4; NY=4; NZ=2 ;;
        36) NX=6; NY=3; NZ=2 ;;
        40) NX=5; NY=4; NZ=2 ;;
        42) NX=7; NY=3; NZ=2 ;;
        44) NX=11; NY=2; NZ=2 ;;
        48) NX=6; NY=4; NZ=2 ;;
        50) NX=5; NY=5; NZ=2 ;;
        *)  NX=1; NY=1; NZ="$N" ;;
    esac

    rm -rf processor* || true
    rm -rf 0
    cp -r 0.orig 0

    cat > system/decomposeParDict <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${N};

method hierarchical;

coeffs
{
    n (${NX} ${NY} ${NZ});
}
EOF

    echo "==> decomposePar N=${N}, hierarchical n=(${NX} ${NY} ${NZ})" | tee -a "$LOGS/run.info"

    decomposePar > "$LOGS/log.decompose.${N}" 2> "$LOGS/err.decompose.${N}"

    echo "==> mpirun -np ${N} fireFoam -parallel" | tee -a "$LOGS/run.info"

    mpirun $MPI_FLAGS -np "$N" fireFoam -parallel -case . \
        > "$LOGS/log.${N}proc" \
        2> "$LOGS/err.${N}proc"

    echo "==== Done N=$N ===="
done

echo "==> Finished all host hierarchical single-node runs"
echo "==> Logs are stored in: $LOGS"

echo "Check final times:"
echo "for N in $PROCS_LIST; do echo -n \"N=\$N final time: \"; grep '^Time =' $LOGS/log.\${N}proc | tail -n 1; done"

echo "Check timesteps:"
echo "for N in $PROCS_LIST; do echo -n \"N=\$N steps: \"; grep -c '^Time =' $LOGS/log.\${N}proc; done"

echo "Check iterations:"
echo "for N in $PROCS_LIST; do echo -n \"N=\$N iterations: \"; grep -c 'No Iterations' $LOGS/log.\${N}proc; done"

echo "Check execution times:"
echo "for N in $PROCS_LIST; do echo -n \"N=\$N: \"; grep 'ExecutionTime' $LOGS/log.\${N}proc | tail -n 1; done"
