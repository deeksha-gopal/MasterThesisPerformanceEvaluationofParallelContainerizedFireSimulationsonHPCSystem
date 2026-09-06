#!/bin/bash
#SBATCH --job-name=pato_container_clean
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=2
#SBATCH --ntasks=32
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

IMG="/beegfs/gopal/pato/pato.sif"
CASE_IN_IMG="/opt/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"

ROOT="/beegfs/gopal/pato/pato_container_clean_2node_32proc_${SLURM_JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"

REGION="porousMat"
PROCS_LIST="2 4 6 8 10 12 16 20 24 32"

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Image: $IMG"
echo "==> Root: $ROOT"
echo "==> Processor list: $PROCS_LIST"
echo "==> SLURM nodes:"
scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "$LOGS/nodes.txt"

module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

HOSTFILE="$LOGS/hostfile"
rm -f "$HOSTFILE"

while read -r NODE; do
    echo "${NODE} slots=${SLURM_NTASKS_PER_NODE}" >> "$HOSTFILE"
done < "$LOGS/nodes.txt"

echo "==> Hostfile:"
cat "$HOSTFILE"

echo "==> Copying tutorial case from container"
apptainer exec --bind "${BASE_CASE}:/case" "$IMG" bash -lc "
    set -e
    cp -a '${CASE_IN_IMG}/.' /case/
"

echo "==> Generating blockMeshDict with m4"
mkdir -p "$BASE_CASE/constant/$REGION/polyMesh"

if command -v m4 >/dev/null 2>&1; then
    M4_BIN=m4
else
    module load M4 2>/dev/null || module load gm4 2>/dev/null || true

    if command -v m4 >/dev/null 2>&1; then
        M4_BIN=m4
    elif command -v gm4 >/dev/null 2>&1; then
        M4_BIN=gm4
    else
        echo "ERROR: No m4/gm4 available"
        exit 2
    fi
fi

"$M4_BIN" "$BASE_CASE/cylinderMesh.m4" > "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"

if grep -q "changecom(" "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"; then
    echo "ERROR: blockMeshDict contains changecom(. Do not use m4 -P."
    exit 3
fi

echo "==> Preparing base 0 directory"
rm -rf "$BASE_CASE/0"
cp -r "$BASE_CASE/origin.0" "$BASE_CASE/0"

echo "==> Running base mesh check"

mkdir -p "$BASE_CASE/logs"

apptainer exec --bind "${BASE_CASE}:/case" "$IMG" bash -lc "
    set +e

    mkdir -p /case/logs

    export ZSH_NAME=''
    export WM_PROJECT_SITE=''
    export WM_PROJECT_USER_DIR=/case/.foam_user
    export FOAM_USER_APPBIN=/case/.foam_user_appbin
    mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\"

    echo 'Sourcing OpenFOAM...' | tee /case/logs/source_check.log
    source /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
    rc1=\$?
    echo \"OpenFOAM source rc=\$rc1\" | tee -a /case/logs/source_check.log

    echo 'Sourcing PATO...' | tee -a /case/logs/source_check.log
    source /opt/pato-3.1/bashrc
    rc2=\$?
    echo \"PATO source rc=\$rc2\" | tee -a /case/logs/source_check.log

    if [ \$rc1 -ne 0 ] || [ \$rc2 -ne 0 ]; then
        echo 'ERROR: OpenFOAM/PATO source failed'
        exit 10
    fi

    unset FOAM_SIGFPE
    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close

    cd /case

    echo 'Running blockMesh...' | tee -a logs/source_check.log
    blockMesh -region $REGION > logs/log.blockMesh.$REGION 2> logs/err.blockMesh.$REGION
    rc=\$?
    echo \"blockMesh rc=\$rc\" | tee -a logs/source_check.log

    if [ \$rc -ne 0 ]; then
        echo 'ERROR: blockMesh failed'
        cat logs/err.blockMesh.$REGION
        exit \$rc
    fi

    echo 'Running checkMesh...' | tee -a logs/source_check.log
    checkMesh -region $REGION > logs/log.checkMesh.$REGION 2> logs/err.checkMesh.$REGION
    rc=\$?
    echo \"checkMesh rc=\$rc\" | tee -a logs/source_check.log

    if [ \$rc -ne 0 ]; then
        echo 'ERROR: checkMesh failed'
        cat logs/err.checkMesh.$REGION
        exit \$rc
    fi
"

echo "==> Base mesh logs:"
ls -lh "$BASE_CASE/logs"

rm -rf "$LOGS/base_mesh_logs"
cp -a "$BASE_CASE/logs" "$LOGS/base_mesh_logs"

echo "==> Starting PATO processor sweep"

for N in $PROCS_LIST; do
    echo "======================================"
    echo "Running N=$N"
    echo "======================================"

    if [ $((N % SLURM_JOB_NUM_NODES)) -ne 0 ]; then
        echo "Skipping N=$N because not divisible by nodes=$SLURM_JOB_NUM_NODES"
        continue
    fi

    PPN=$((N / SLURM_JOB_NUM_NODES))

    RUN_CASE="${RUNS_DIR}/case_N${N}"

    rm -rf "$RUN_CASE"
    mkdir -p "$RUN_CASE"

    cp -a "$BASE_CASE/." "$RUN_CASE/"

    cd "$RUN_CASE"

    rm -rf processor* postProcessing logs
    mkdir -p logs

    rm -rf 0
    cp -r origin.0 0

    mkdir -p "system/$REGION"

    cat > system/decomposeParDict <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains $N;

method scotch;
EOF

    cp system/decomposeParDict "system/$REGION/decomposeParDict"

    echo "==> Running decomposePar inside container for N=$N"

    apptainer exec --bind "${RUN_CASE}:/case" "$IMG" bash -lc "
        set +e

        mkdir -p /case/logs

        export ZSH_NAME=''
        export WM_PROJECT_SITE=''
        export WM_PROJECT_USER_DIR=/case/.foam_user
        export FOAM_USER_APPBIN=/case/.foam_user_appbin
        mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\"

        source /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
        rc1=\$?

        source /opt/pato-3.1/bashrc
        rc2=\$?

        echo \"OpenFOAM source rc=\$rc1\" > /case/logs/decompose_source_check.$N.log
        echo \"PATO source rc=\$rc2\" >> /case/logs/decompose_source_check.$N.log

        if [ \$rc1 -ne 0 ] || [ \$rc2 -ne 0 ]; then
            echo 'ERROR: source failed during decomposePar'
            exit 20
        fi

        unset FOAM_SIGFPE
        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close

        cd /case

        decomposePar -region $REGION > logs/log.decompose.$REGION.$N 2> logs/err.decompose.$REGION.$N
        rc=\$?

        echo \"decomposePar rc=\$rc\" >> logs/decompose_source_check.$N.log

        if [ \$rc -ne 0 ]; then
            echo 'ERROR: decomposePar failed for N=$N'
            cat logs/err.decompose.$REGION.$N
            exit \$rc
        fi
    "

    echo "==> Running PATOx container N=$N, PPN=$PPN"

    START_TIME=$(date +%s)

    mpirun \
        --hostfile "$HOSTFILE" \
        --map-by ppr:${PPN}:node \
        --bind-to core \
        -np "$N" \
        apptainer exec --bind "${RUN_CASE}:/case" "$IMG" \
        bash -lc "
            export ZSH_NAME=''
            export WM_PROJECT_SITE=''
            export WM_PROJECT_USER_DIR=/case/.foam_user
            export FOAM_USER_APPBIN=/case/.foam_user_appbin
            mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\"

            source /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
            source /opt/pato-3.1/bashrc

            unset FOAM_SIGFPE
            export OMP_NUM_THREADS=1
            export OMP_PROC_BIND=close

            cd /case

            /opt/pato-3.1/install/bin/PATOx -parallel -case .
        " > "logs/log.${N}proc" 2> "logs/err.${N}proc"

    RC=$?

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    {
        echo ""
        echo "=============================="
        echo "Timing information"
        echo "N = $N"
        echo "Nodes = $SLURM_JOB_NUM_NODES"
        echo "Ranks per node = $PPN"
        echo "Decomposition = scotch"
        echo "Elapsed wall time = ${ELAPSED} s"
        echo "=============================="
    } >> "logs/log.${N}proc"

    if [ $RC -ne 0 ]; then
        echo "ERROR: PATOx failed for N=$N"
        echo "---- err.${N}proc ----"
        tail -n 100 "logs/err.${N}proc" || true
        exit $RC
    fi

    cp -a "$RUN_CASE/logs" "$LOGS/logs_N${N}"

    echo "==== Done N=$N ===="
done

echo "==> Finished all PATO container multi-node runs"
echo "==> Root folder: $ROOT"
