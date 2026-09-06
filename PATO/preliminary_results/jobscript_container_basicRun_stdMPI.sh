#!/bin/bash
#SBATCH --job-name=pato_container_clean
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=12
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

IMG="/beegfs/gopal/pato/pato.sif"
CASE_IN_IMG="/opt/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"

ROOT="/beegfs/gopal/pato/pato_container_${SLURM_JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"

REGION="porousMat"
PROCS_LIST="2 4 6 8 10 12"

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Image: $IMG"
echo "==> Root: $ROOT"
echo "==> Processor list: $PROCS_LIST"

if ! type module &>/dev/null; then
    [ -f /etc/profile.d/modules.sh ] && source /etc/profile.d/modules.sh || true
fi

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
apptainer exec --bind "${BASE_CASE}:/case" "$IMG" bash -lc "
    set +e

    LOGDIR=/case/logs
    mkdir -p \"\$LOGDIR\"

    : \${ZSH_NAME:=}
    : \${WM_PROJECT_SITE:=}

    export WM_PROJECT_USER_DIR=/case/.foam_user
    export FOAM_USER_APPBIN=/case/.foam_user_appbin
    mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\"

    source /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
    source /opt/pato-3.1/bashrc

    unset FOAM_SIGFPE
    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close

    cd /case

    blockMesh -region $REGION > logs/log.blockMesh.$REGION 2> logs/err.blockMesh.$REGION
    rc=\$?
    if [ \$rc -ne 0 ]; then
        echo 'ERROR: blockMesh failed'
        cat logs/err.blockMesh.$REGION
        exit \$rc
    fi

    checkMesh -region $REGION > logs/log.checkMesh.$REGION 2> logs/err.checkMesh.$REGION
    rc=\$?
    if [ \$rc -ne 0 ]; then
        echo 'ERROR: checkMesh failed'
        cat logs/err.checkMesh.$REGION
        exit \$rc
    fi
"

cp -a "$BASE_CASE/logs" "$LOGS/base_mesh_logs"

for N in $PROCS_LIST; do
    echo "======================================"
    echo "Running N=$N"
    echo "======================================"

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

    apptainer exec --bind "${RUN_CASE}:/case" "$IMG" bash -lc "
        set +e

        LOGDIR=/case/logs

        : \${ZSH_NAME:=}
        : \${WM_PROJECT_SITE:=}

        export WM_PROJECT_USER_DIR=/case/.foam_user
        export FOAM_USER_APPBIN=/case/.foam_user_appbin
        mkdir -p \"\$WM_PROJECT_USER_DIR\" \"\$FOAM_USER_APPBIN\"

        source /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
        source /opt/pato-3.1/bashrc

        unset FOAM_SIGFPE
        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close

        cd /case

        {
            echo 'Host inside container:' \$(hostname)
            echo 'foamVersion:'
            foamVersion || true
            echo 'PATOx:' /opt/pato-3.1/install/bin/PATOx
            echo 'blockMesh:' \$(command -v blockMesh || true)
            echo 'decomposePar:' \$(command -v decomposePar || true)
            echo 'mpirun:' \$(command -v mpirun || true)
        } > \"\$LOGDIR/run.info\" 2>&1

        decomposePar -region $REGION > \"\$LOGDIR/log.decompose.$REGION.$N\" 2> \"\$LOGDIR/err.decompose.$REGION.$N\"
        rc=\$?
        if [ \$rc -ne 0 ]; then
            echo 'ERROR: decomposePar failed for N=$N'
            cat \"\$LOGDIR/err.decompose.$REGION.$N\"
            exit \$rc
        fi

        mpirun -np $N /opt/pato-3.1/install/bin/PATOx -parallel -case . \
            > \"\$LOGDIR/log.${N}proc\" \
            2> \"\$LOGDIR/err.${N}proc\"

        rc=\$?
        if [ \$rc -ne 0 ]; then
            echo 'ERROR: PATOx failed for N=$N'
            cat \"\$LOGDIR/err.${N}proc\"
            exit \$rc
        fi
    "

    cp -a "$RUN_CASE/logs" "$LOGS/logs_N${N}"

    echo "==== Done N=$N ===="
done

echo "==> Finished all container runs"
echo "==> Root folder: $ROOT"

echo
echo "Check summary:"
echo "ROOT=$ROOT"
echo 'for N in 2 4 6 8 10 12; do'
echo '  LOG=$ROOT/runs/case_N${N}/logs/log.${N}proc'
echo '  echo "===== N=$N ====="'
echo '  grep "runTime =" "$LOG" | tail -n 1'
echo '  echo -n "runTime count: "; grep -c "runTime =" "$LOG"'
echo '  grep "ExecutionTime" "$LOG" | tail -n 1'
echo '  grep "No Iterations" "$LOG" | awk "{print \$NF}" | sort | uniq -c'
echo '  grep -i "fatal\|nan\|segmentation" "$LOG" || echo "No fatal/nan errors"'
echo 'done'
