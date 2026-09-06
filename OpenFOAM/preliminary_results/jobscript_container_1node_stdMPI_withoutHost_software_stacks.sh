

#!/bin/bash
#SBATCH --job-name=openfoam_inside_container_fixedIter
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

IMG="/beegfs/gopal/openfoam/openfoam_v2406.sif"
CASE_IN_IMG="/opt/OpenFOAM/OpenFOAM-v2406/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
CASE_HOST="/beegfs/gopal/openfoam/smallPoolFire3D_container_fixedIter_hierarchical_mesh120_${SLURM_JOB_ID}"
LOGS_HOST="${CASE_HOST}/logs"

PROCS_LIST="${PROCS_LIST:-2 4 6 8 10 12 16 20 32 36 40 42 44 48 50}"
MPI_FLAGS="${MPI_FLAGS:---oversubscribe}"

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Image: $IMG"
echo "==> Case inside image: $CASE_IN_IMG"
echo "==> Host case directory: $CASE_HOST"
echo "==> Processor list: $PROCS_LIST"
echo "==> Decomposition method: hierarchical"

rm -rf "$CASE_HOST"
mkdir -p "$LOGS_HOST"

echo "==> Copying tutorial case from container to host"
apptainer exec --bind "${CASE_HOST}:${CASE_HOST}" "$IMG" \
    /bin/bash -lc "cp -a '${CASE_IN_IMG}/.' '${CASE_HOST}/'"

echo "==> Updating mesh to 80x80x80"
sed -i 's/(60[[:space:]]\+60[[:space:]]\+60)/(120 120 120)/' "$CASE_HOST/system/blockMeshDict"

echo "==> Updating controlDict"
sed -i 's/^[[:space:]]*deltaT[[:space:]].*/deltaT          0.00075;/' "$CASE_HOST/system/controlDict"
sed -i 's/^[[:space:]]*maxCo[[:space:]].*/maxCo           0.45;/' "$CASE_HOST/system/controlDict"
sed -i 's/^[[:space:]]*adjustTimeStep[[:space:]].*/adjustTimeStep  no;/' "$CASE_HOST/system/controlDict"
sed -i 's/^[[:space:]]*endTime[[:space:]].*/endTime         0.075;/' "$CASE_HOST/system/controlDict"
sed -i 's/^[[:space:]]*writeControl[[:space:]].*/writeControl    timeStep;/' "$CASE_HOST/system/controlDict"
sed -i 's/^[[:space:]]*writeInterval[[:space:]].*/writeInterval   100;/' "$CASE_HOST/system/controlDict"

echo "==> Removing old functions block"
sed -i '/^functions[[:space:]]*$/,$d' "$CASE_HOST/system/controlDict"

cat >> "$CASE_HOST/system/controlDict" <<'EOF'

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
cat > "$CASE_HOST/system/fvSolution" <<'EOF'
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

run_in_img() {
    local case_script="$1"

    apptainer exec --bind "${CASE_HOST}:/case" "$IMG" \
        /bin/bash -lc "
            set +u
            export ZSH_NAME=''
            export WM_PROJECT_SITE=''
            export HOME=/case
            export WM_PROJECT_USER_DIR=/case/.foam_user
            export FOAM_USER_APPBIN=/case/.foam_user_appbin
            mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\" /case/logs
            source /opt/OpenFOAM/OpenFOAM-v2406/etc/bashrc
            export OMP_NUM_THREADS=1
            export OMP_PROC_BIND=close
            cd /case
            bash /case/${case_script}
        "
}

cat > "${CASE_HOST}/prep_case.sh" <<'EOF'
#!/bin/bash
set -e
set -o pipefail

rm -rf 0
cp -r 0.orig 0
rm -rf constant/polyMesh

blockMesh > /case/logs/log.blockMesh 2> /case/logs/err.blockMesh
checkMesh > /case/logs/log.checkMesh 2> /case/logs/err.checkMesh
EOF

chmod +x "${CASE_HOST}/prep_case.sh"

echo "==> Preparing mesh"
run_in_img "prep_case.sh"

echo "==> Starting single-node hierarchical processor sweep"

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

    RUNSCRIPT="${CASE_HOST}/run_${N}.sh"

    cat > "$RUNSCRIPT" <<EOF
#!/bin/bash
set -e
set -o pipefail

rm -rf processor* || true
rm -rf 0
cp -r 0.orig 0

cat > system/decomposeParDict <<'DICT'
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
DICT

echo "==> decomposePar N=${N}, hierarchical n=(${NX} ${NY} ${NZ})" | tee -a /case/logs/run.info
decomposePar > /case/logs/log.decompose.${N} 2> /case/logs/err.decompose.${N}

echo "==> mpirun -np ${N} fireFoam -parallel" | tee -a /case/logs/run.info
mpirun ${MPI_FLAGS} -np ${N} fireFoam -parallel -case . > /case/logs/log.${N}proc 2> /case/logs/err.${N}proc
EOF

    chmod +x "$RUNSCRIPT"

    if ! run_in_img "run_${N}.sh"; then
        echo "ERROR: Run failed for N=$N"
        tail -n 120 "${LOGS_HOST}/err.decompose.${N}" 2>/dev/null || true
        tail -n 120 "${LOGS_HOST}/err.${N}proc" 2>/dev/null || true
        tail -n 120 "${LOGS_HOST}/log.${N}proc" 2>/dev/null || true
        exit 10
    fi

    echo "==== Done N=$N ===="
done

echo "==> Finished all single-node hierarchical runs"
echo "==> Logs are stored in: ${LOGS_HOST}"
