#!/bin/bash
#SBATCH --job-name=pato4096k
#SBATCH --output=pato4096k_%j.out
#SBATCH --error=pato4096k_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=4
#SBATCH --ntasks=200
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

RUNTIME="${RUNTIME:-host}"

NODES="${SLURM_JOB_NUM_NODES:-0}"
TASKS="${SLURM_NTASKS:-0}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"
JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

MPI_PML="ob1"
MPI_BTL="self,tcp"

REGION="porousMat"

DELTA_T="0.00075"
END_TIME="0.075"
EXPECTED_STEPS=100
ADJUST_TIME_STEP="no"
MAX_CO="0.45"

NPS=64
NPD=34
NPY=320
EXPECTED_CELLS=4096000

# Fixed work per solver call. Negative nSweeps forces the fixed-sweep branch in OpenFOAM-7 smoothSolver.
MOTION_SWEEPS=300
P_SWEEPS=200
TA_SWEEPS=15
XSI_SWEEPS=1
YI_SWEEPS=1
ZI_SWEEPS=1
RT_SWEEPS=1

REFERENCE_SIGNATURE_INPUT="${REFERENCE_SIGNATURE_INPUT:-}"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES || true

die(){ echo "ERROR: $*" >&2; exit 1; }
require_file(){ [[ -f "$1" ]] || die "Required file not found: $1"; }
require_nonempty_file(){ [[ -s "$1" ]] || die "Required file missing/empty: $1"; }
require_dir(){ [[ -d "$1" ]] || die "Required directory not found: $1"; }
require_exec(){ [[ -x "$1" ]] || die "Required executable missing: $1"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }
timestamp(){ date '+%Y-%m-%d %H:%M:%S %Z'; }

elapsed_seconds()
{
    python3 - "$1" "$2" <<'PY'
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PY
}

show_failure_logs()
{
    echo "---------------- stdout ----------------"
    [[ -s "$1" ]] && tail -n 200 "$1" || true
    echo "---------------- stderr ----------------"
    [[ -s "$2" ]] && tail -n 200 "$2" || true
    echo "----------------------------------------"
}

set_entry()
{
    python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); key=sys.argv[2]; value=sys.argv[3]
t=p.read_text()
pat=rf"(?m)^[ \t]*{re.escape(key)}[ \t]+[^;]+;"
rep=f"{key:<18}{value};"
if re.search(pat,t):
    t=re.sub(pat,rep,t,count=1)
else:
    t=t.rstrip()+"\n"+rep+"\n"
p.write_text(t)
PY
}

disable_probing()
{
    python3 - "$1" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); t=p.read_text()
pat=re.compile(r"(?ms)^[ \t]*probingFunctions[ \t]*\n[ \t]*\([ \t]*\n.*?^[ \t]*\)[ \t]*;")
m=list(pat.finditer(t))
if len(m)!=1:
    raise SystemExit(f"Expected one probingFunctions list in {p}, found {len(m)}")
p.write_text(pat.sub("  probingFunctions\n  (\n  );",t,count=1))
PY
}

verify_probing()
{
    python3 - "$1" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); t=p.read_text()
m=re.search(r"(?ms)^[ \t]*probingFunctions[ \t]*\n[ \t]*\((.*?)^[ \t]*\)[ \t]*;",t)
if not m or m.group(1).strip():
    raise SystemExit(f"probingFunctions not disabled in {p}")
print("Confirmed: probingFunctions disabled")
PY
}

case "$RUNTIME" in host|container) ;; *) die "RUNTIME must be host or container";; esac
(( NODES > 0 && TASKS > 0 )) || die "Submit with sbatch"
(( CPUS_PER_TASK == 1 )) || die "Requires --cpus-per-task=1"

case "$NODES" in
    1) PROCS_LIST="2 4 8 10 16 20 25 32 40 50"; REQUIRED_TASKS=50 ;;
    2) PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"; REQUIRED_TASKS=100 ;;
    4) PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"; REQUIRED_TASKS=200 ;;
    *) die "Only 1, 2 and 4 nodes are supported" ;;
esac

(( TASKS >= REQUIRED_TASKS )) || die "Need at least $REQUIRED_TASKS tasks"

for N in $PROCS_LIST; do
    (( N <= TASKS )) || die "$N exceeds allocation"
    (( N % NODES == 0 )) || die "$N cannot balance over $NODES nodes"
    (( N / NODES <= TASKS_PER_NODE )) || die "$N exceeds ranks/node allocation"
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load M4/1.4.19

for C in gcc mpirun python3 awk grep sed m4 find wc sort uniq tee sha256sum cmp diff scontrol; do
    require_cmd "$C"
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"
[[ "$MPI_VERSION" == *4.1.5* ]] || die "Expected OpenMPI 4.1.5, got: $MPI_VERSION"

if [[ "$RUNTIME" == "container" ]]; then
    BASE_ROOT="/beegfs/gopal/new/pato"
    IMAGE="${BASE_ROOT}/pato_image.sif"
    PATO_ROOT="/opt/pato-3.1"
    OPENFOAM_ROOT="/opt/OpenFOAM/OpenFOAM-7"
    HOST_MPI_ENV="/opt/host_mpi_env.sh"
    CASE_SOURCE="${PATO_ROOT}/tutorials/3D/ArcJet_cylinder_3D"
    PATO_BIN="${PATO_ROOT}/install/bin/PATOx"
    ROOT="${BASE_ROOT}/results/ArcJet_cylinder_3D_4096k_container_fixedwork_unified_${NODES}node_${JOB_ID}"

    require_file "$IMAGE"
    require_cmd apptainer

    read -r -d '' CONTAINER_INIT <<EOF || true
set -e
set -o pipefail
test -f '${HOST_MPI_ENV}'
. '${HOST_MPI_ENV}'
export FOAM_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_DIR='${OPENFOAM_ROOT}'
export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-7
export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt
export PATO_DIR='${PATO_ROOT}'
set +e
set +u
set +o pipefail
. '${OPENFOAM_ROOT}/etc/bashrc'; A=\$?
. '${PATO_ROOT}/bashrc'; B=\$?
set -e
set -o pipefail
[ "\$A" -eq 0 ] && [ "\$B" -eq 0 ] || exit 10
. '${HOST_MPI_ENV}'
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES
export OMPI_MCA_pml='${MPI_PML}'
export OMPI_MCA_btl='${MPI_BTL}'
EOF

    run_serial()
    {
        local dir="$1"; shift
        local cmd="$*"
        apptainer exec \
            --cleanenv \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${dir}:/case" \
            --pwd /case \
            "$IMAGE" /bin/bash -lc "${CONTAINER_INIT}; cd /case; ${cmd}"
    }
else
    BASE_ROOT="/beegfs/gopal/new/pato/host"
    OPENFOAM_BASE="${BASE_ROOT}/OpenFOAM"
    OPENFOAM_ROOT="${OPENFOAM_BASE}/OpenFOAM-7"
    PATO_ROOT="${BASE_ROOT}/pato-3.1"
    CASE_SOURCE="${PATO_ROOT}/tutorials/3D/ArcJet_cylinder_3D"
    PATO_BIN="${PATO_ROOT}/install/bin/PATOx"
    ROOT="${BASE_ROOT}/results/ArcJet_cylinder_3D_4096k_host_fixedwork_unified_${NODES}node_${JOB_ID}"

    require_file "${OPENFOAM_ROOT}/etc/bashrc"
    require_file "${PATO_ROOT}/bashrc"
    require_dir "$CASE_SOURCE"
    require_exec "$PATO_BIN"

    export FOAM_INST_DIR="$OPENFOAM_BASE"
    export WM_PROJECT_INST_DIR="$OPENFOAM_BASE"
    export WM_PROJECT_DIR="$OPENFOAM_ROOT"
    export WM_THIRD_PARTY_DIR="${OPENFOAM_BASE}/ThirdParty-7"
    export WM_COMPILER_TYPE=system
    export WM_COMPILER=Gcc
    export WM_MPLIB=SYSTEMOPENMPI
    export WM_PRECISION_OPTION=DP
    export WM_LABEL_SIZE=32
    export WM_COMPILE_OPTION=Opt
    export PATO_DIR="$PATO_ROOT"

    set +e; set +u; set +o pipefail
    . "${OPENFOAM_ROOT}/etc/bashrc"; A=$?
    . "${PATO_ROOT}/bashrc"; B=$?
    set -e; set -o pipefail
    (( A==0 && B==0 )) || die "OpenFOAM/PATO environment failed"

    run_serial()
    {
        local dir="$1"; shift
        ( cd "$dir"; "$@" )
    }
fi

BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"
WORKLOAD_SUMMARY="${ROOT}/workload_summary.tsv"
REFERENCE_SIGNATURE="${ROOT}/reference_solver_signature.txt"

rm -rf "$ROOT"
mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS_DIR"
exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

echo "=================================================================="
echo "PATO UNIFIED CONTROLLED FIXED-WORK BENCHMARK"
echo "=================================================================="
echo "Runtime: $RUNTIME"
echo "Nodes: $NODES"
echo "Ranks: $PROCS_LIST"
echo "MPI: $MPI_VERSION"
echo "PML/BTL: $MPI_PML / $MPI_BTL"
echo "Cells: $EXPECTED_CELLS"
echo "deltaT: $DELTA_T"
echo "endTime: $END_TIME"
echo "adjustTimeStep: $ADJUST_TIME_STEP"
echo "maxCo: $MAX_CO"
echo "Expected steps: $EXPECTED_STEPS"
echo "cellMotionU: $MOTION_SWEEPS fixed sweeps/call"
echo "p: $P_SWEEPS fixed sweeps/call"
echo "Ta: $TA_SWEEPS fixed sweeps/call"
echo "Xsii/Yi/Zi/rT: 1 fixed sweep/call"
echo "=================================================================="

scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "${LOGS_DIR}/allocated_nodes.txt"

if [[ "$RUNTIME" == "container" ]]; then
    run_serial "$BASE_CASE" "cp -a '${CASE_SOURCE}/.' /case/"
else
    cp -a "${CASE_SOURCE}/." "${BASE_CASE}/"
fi

require_file "${BASE_CASE}/system/controlDict"
require_file "${BASE_CASE}/cylinderMesh.m4"
require_dir "${BASE_CASE}/origin.0"
require_nonempty_file "${BASE_CASE}/system/${REGION}/fvSolution"
require_nonempty_file "${BASE_CASE}/constant/${REGION}/BoundaryConditions"
require_nonempty_file "${BASE_CASE}/constant/${REGION}/fluxFactorMap"
require_nonempty_file "${BASE_CASE}/constant/${REGION}/porousMatProperties"

disable_probing "${BASE_CASE}/constant/${REGION}/porousMatProperties"
verify_probing "${BASE_CASE}/constant/${REGION}/porousMatProperties"

CONTROL="${BASE_CASE}/system/controlDict"
set_entry "$CONTROL" deltaT "$DELTA_T"
set_entry "$CONTROL" endTime "$END_TIME"
set_entry "$CONTROL" adjustTimeStep "$ADJUST_TIME_STEP"
set_entry "$CONTROL" maxCo "$MAX_CO"
set_entry "$CONTROL" writeControl timeStep
set_entry "$CONTROL" writeInterval "$EXPECTED_STEPS"

FVSOLUTION="${BASE_CASE}/system/${REGION}/fvSolution"

cat > "$FVSOLUTION" <<EOF
FoamFile
{
    version 2.0;
    format ascii;
    class dictionary;
    object fvSolution;
}

solvers
{
    cellMotionU
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${MOTION_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    cellMotionUx { \$cellMotionU; }
    cellMotionUy { \$cellMotionU; }
    cellMotionUz { \$cellMotionU; }

    p
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${P_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    Ta
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${TA_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    Xsii
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${XSI_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    Yi
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${YI_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    Zi
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${ZI_SWEEPS};
        tolerance 0;
        relTol 0;
    }

    rT
    {
        solver smoothSolver;
        smoother GaussSeidel;
        nSweeps -${RT_SWEEPS};
        tolerance 0;
        relTol 0;
    }
}

SIMPLE
{
    nNonOrthogonalCorrectors 0;
}

relaxationFactors
{
    fields {}
    equations { ".*" 1; }
}
EOF

cp "$FVSOLUTION" "${ROOT}/fvSolution.fixed_work"
FVSOLUTION_HASH="$(sha256sum "$FVSOLUTION" | awk '{print $1}')"

python3 - "${BASE_CASE}/cylinderMesh.m4" "$NPS" "$NPD" "$NPY" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); t=p.read_text()
for k,v in {"NPS":sys.argv[2],"NPD":sys.argv[3],"NPY":sys.argv[4]}.items():
    pat=rf"(?m)^(\s*define\(\s*{k}\s*,\s*)[^)]+(\).*)$"
    if not re.search(pat,t): raise SystemExit(f"Missing {k}")
    t=re.sub(pat,rf"\g<1>{v}\g<2>",t,count=1)
p.write_text(t)
PY

mkdir -p "${BASE_CASE}/constant/${REGION}/polyMesh"
m4 "${BASE_CASE}/cylinderMesh.m4" > "${BASE_CASE}/constant/${REGION}/polyMesh/blockMeshDict"
rm -rf "${BASE_CASE}/0"
cp -a "${BASE_CASE}/origin.0" "${BASE_CASE}/0"

if [[ "$RUNTIME" == "container" ]]; then
    run_serial "$BASE_CASE" "blockMesh -region '${REGION}' > /case/log.blockMesh 2> /case/err.blockMesh"
    run_serial "$BASE_CASE" "checkMesh -region '${REGION}' > /case/log.checkMesh 2> /case/err.checkMesh"
else
    ( cd "$BASE_CASE"; blockMesh -region "$REGION" > log.blockMesh 2> err.blockMesh )
    ( cd "$BASE_CASE"; checkMesh -region "$REGION" > log.checkMesh 2> err.checkMesh )
fi

grep -q "Mesh OK" "${BASE_CASE}/log.checkMesh" || die "checkMesh failed"
DETECTED_CELLS="$(awk '/^[[:space:]]*cells:/ {x=$2} END{print x}' "${BASE_CASE}/log.checkMesh")"
[[ "$DETECTED_CELLS" == "$EXPECTED_CELLS" ]] || die "Cell count mismatch"

printf 'nodes\tranks\tppn\tsteps\tfinal_time\tfinal_dt\tsolver_calls\ttotal_work\texternal_s\tstatus\tcase\n' > "$SUMMARY_FILE"
printf 'ranks\tsteps\tsolver_calls\ttotal_work\tsignature_status\n' > "$WORKLOAD_SUMMARY"

REFERENCE_N=""
if [[ -n "$REFERENCE_SIGNATURE_INPUT" ]]; then
    require_nonempty_file "$REFERENCE_SIGNATURE_INPUT"
    cp "$REFERENCE_SIGNATURE_INPUT" "$REFERENCE_SIGNATURE"
    REFERENCE_N="EXTERNAL"
fi

for N in $PROCS_LIST; do
    PPN=$((N/NODES))

    RUN_DIR="${RUNS_DIR}/case_N${N}"
    RUN_LOG_DIR="${RUN_DIR}/logs"
    RUN_LOG="${RUN_LOG_DIR}/log.${N}proc"
    RUN_ERR="${RUN_LOG_DIR}/err.${N}proc"
    DECOMP_LOG="${RUN_LOG_DIR}/log.decompose.${N}"
    DECOMP_ERR="${RUN_LOG_DIR}/err.decompose.${N}"
    PLACEMENT_RAW="${RUN_LOG_DIR}/placement.${N}.raw"
    PLACEMENT_ERR="${RUN_LOG_DIR}/placement.${N}.err"
    SIGNATURE="${RUN_LOG_DIR}/solver_signature.${N}.txt"

    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    cp -a "${BASE_CASE}/." "$RUN_DIR/"
    rm -rf "${RUN_DIR}/processor"* "${RUN_DIR}/0"
    cp -a "${RUN_DIR}/origin.0" "${RUN_DIR}/0"
    rm -rf "${RUN_DIR}/output"
    mkdir -p "${RUN_DIR}/output/empty" "$RUN_LOG_DIR" "${RUN_DIR}/system/${REGION}"

    cp -f "${ROOT}/fvSolution.fixed_work" "${RUN_DIR}/system/${REGION}/fvSolution"
    cmp -s "${ROOT}/fvSolution.fixed_work" "${RUN_DIR}/system/${REGION}/fvSolution" ||
        die "fvSolution mismatch N=$N"
    [[ "$(sha256sum "${RUN_DIR}/system/${REGION}/fvSolution" | awk '{print $1}')" == "$FVSOLUTION_HASH" ]] ||
        die "fvSolution hash mismatch N=$N"

    verify_probing "${RUN_DIR}/constant/${REGION}/porousMatProperties"

    cat > "${RUN_DIR}/system/decomposeParDict" <<EOF
FoamFile
{
    version 2.0;
    format ascii;
    class dictionary;
    object decomposeParDict;
}
numberOfSubdomains ${N};
method scotch;
distributed no;
roots ();
EOF
    cp "${RUN_DIR}/system/decomposeParDict" "${RUN_DIR}/system/${REGION}/decomposeParDict"

    if [[ "$RUNTIME" == "container" ]]; then
        run_serial "$RUN_DIR" "decomposePar -region '${REGION}' > /case/logs/log.decompose.${N} 2> /case/logs/err.decompose.${N}"
    else
        ( cd "$RUN_DIR"; decomposePar -region "$REGION" > "$DECOMP_LOG" 2> "$DECOMP_ERR" )
    fi

    grep -q "^End$" "$DECOMP_LOG" || die "decomposePar failed N=$N"

    set +e
    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        --map-by "ppr:${PPN}:node:PE=1" \
        --bind-to core \
        -np "$N" hostname \
        > "$PLACEMENT_RAW" 2> "$PLACEMENT_ERR"
    PRC=$?
    set -e
    (( PRC==0 )) || die "Placement test failed N=$N"

    HOSTS="$(sort -u "$PLACEMENT_RAW" | wc -l | tr -d '[:space:]')"
    [[ "$HOSTS" -eq "$NODES" ]] || die "Expected $NODES hosts, used $HOSTS"

    echo
    echo "=================================================================="
    echo "PRE-LAUNCH N=$N"
    echo "=================================================================="
    echo "nodes=$NODES ranks=$N ppn=$PPN"
    echo "deltaT=$DELTA_T endTime=$END_TIME adjustTimeStep=$ADJUST_TIME_STEP maxCo=$MAX_CO"
    echo "expected_steps=$EXPECTED_STEPS"
    echo "fvSolution_hash=$FVSOLUTION_HASH"
    echo "motion=$MOTION_SWEEPS p=$P_SWEEPS Ta=$TA_SWEEPS Xsi=$XSI_SWEEPS"
    echo "=================================================================="

    START="$(date +%s.%N)"

    set +e
    if [[ "$RUNTIME" == "container" ]]; then

        PAR_CMD="$(
            cat <<EOF
${CONTAINER_INIT}
cd /case
test -s system/${REGION}/fvSolution
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMPI_MCA_pml=${MPI_PML}
export OMPI_MCA_btl=${MPI_BTL}
exec '${PATO_BIN}' -parallel -case .
EOF
        )"

        mpirun \
            --mca pml "$MPI_PML" \
            --mca btl "$MPI_BTL" \
            --map-by "ppr:${PPN}:node:PE=1" \
            --bind-to core \
            -np "$N" \
            apptainer exec \
                --bind /beegfs/Tools:/beegfs/Tools:ro \
                --bind "${RUN_DIR}:/case" \
                --pwd /case \
                --env OMP_NUM_THREADS=1 \
                --env OMP_PROC_BIND=close \
                --env OMPI_MCA_pml="$MPI_PML" \
                --env OMPI_MCA_btl="$MPI_BTL" \
                "$IMAGE" /bin/bash -lc "$PAR_CMD" \
            > "$RUN_LOG" 2> "$RUN_ERR"
    else
        (
            cd "$RUN_DIR"
            export OMP_NUM_THREADS=1
            export OMP_PROC_BIND=close
            export OMPI_MCA_pml="$MPI_PML"
            export OMPI_MCA_btl="$MPI_BTL"

            mpirun \
                --mca pml "$MPI_PML" \
                --mca btl "$MPI_BTL" \
                --map-by "ppr:${PPN}:node:PE=1" \
                --bind-to core \
                -np "$N" \
                "$PATO_BIN" -parallel -case . \
                > "$RUN_LOG" 2> "$RUN_ERR"
        )
    fi
    RC=$?
    set -e

    END="$(date +%s.%N)"
    EXT="$(elapsed_seconds "$START" "$END")"

    if (( RC != 0 )); then
        show_failure_logs "$RUN_LOG" "$RUN_ERR"
        die "PATO failed N=$N RC=$RC"
    fi

    if grep -Eiq \
       -- '--> FOAM FATAL ERROR|--> FOAM FATAL IO ERROR|MPI_ABORT|Segmentation fault|Signal: Floating point exception|Floating point exception \(core dumped\)|Killed process|Out of memory' \
       "$RUN_LOG" "$RUN_ERR"; then
        show_failure_logs "$RUN_LOG" "$RUN_ERR"
        die "Fatal runtime error N=$N"
    fi

    grep -q 'Finalising parallel run' "$RUN_LOG" || die "No finalisation N=$N"

    STEPS="$(grep -c '^[[:space:]]*runTime[[:space:]]*=' "$RUN_LOG" || true)"
    [[ "$STEPS" -eq "$EXPECTED_STEPS" ]] || die "Step mismatch N=$N: $STEPS"

    FINAL_TIME="$(sed -nE 's/.*runTime[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' "$RUN_LOG" | tail -1)"
    FINAL_DT="$(sed -nE 's/.*Time step[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' "$RUN_LOG" | tail -1)"

    python3 - "$FINAL_TIME" "$END_TIME" "$FINAL_DT" "$DELTA_T" <<'PY'
import math,sys
a=float(sys.argv[1].replace("D","E").replace("d","e"))
b=float(sys.argv[2])
c=float(sys.argv[3].replace("D","E").replace("d","e"))
d=float(sys.argv[4])
if not math.isclose(a,b,rel_tol=0,abs_tol=1e-10):
    raise SystemExit(f"endTime mismatch: {a} != {b}")
if not math.isclose(c,d,rel_tol=0,abs_tol=1e-12):
    raise SystemExit(f"dt mismatch: {c} != {d}")
PY

    grep 'Solving for' "$RUN_LOG" |
    sed -n 's/.*Solving for \([^,]*\).*No Iterations \([0-9][0-9]*\).*/\1 \2/p' |
    awk '
    {
        f=$1; c[f]++; t[f]+=$2
        if (!(f in mn) || $2<mn[f]) mn[f]=$2
        if (!(f in mx) || $2>mx[f]) mx[f]=$2
    }
    END{
        for(f in c)
            printf "%-30s %10d %15d %10d %10d\n",f,c[f],t[f],mn[f],mx[f]
    }' | sort > "$SIGNATURE"

    require_nonempty_file "$SIGNATURE"

    python3 - "$SIGNATURE" "$MOTION_SWEEPS" "$P_SWEEPS" "$TA_SWEEPS" "$XSI_SWEEPS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
motion,pw,taw,xw=map(int,sys.argv[2:6])
r={}
for line in p.read_text().splitlines():
    a=line.split()
    if len(a)==5:
        r[a[0]]=dict(calls=int(a[1]),total=int(a[2]),mn=int(a[3]),mx=int(a[4]))
def chk(f,w):
    if f not in r: raise SystemExit(f"Missing {f}")
    x=r[f]
    if x["mn"]!=w or x["mx"]!=w or x["total"]!=x["calls"]*w:
        raise SystemExit(f"{f} fixed-work mismatch: {x}, expected {w}")
chk("p",pw); chk("Ta",taw)
for f in ("cellMotionUx","cellMotionUy","cellMotionUz"): chk(f,motion)
xs=[f for f in r if f.startswith("Xsi[")]
if not xs: raise SystemExit("No Xsi fields found")
for f in xs: chk(f,xw)
print("Fixed solver-work validation passed.")
PY

    SOLVER_CALLS="$(awk '{s+=$2} END{print s+0}' "$SIGNATURE")"
    TOTAL_WORK="$(awk '{s+=$3} END{print s+0}' "$SIGNATURE")"

    if [[ -z "$REFERENCE_N" ]]; then
        REFERENCE_N="$N"
        cp "$SIGNATURE" "$REFERENCE_SIGNATURE"
        STATUS="REFERENCE"
    else
        if diff -u "$REFERENCE_SIGNATURE" "$SIGNATURE" > "${RUN_LOG_DIR}/solver_signature.diff"; then
            STATUS="MATCH"
        else
            cat "${RUN_LOG_DIR}/solver_signature.diff"
            die "Solver call/work signature mismatch N=$N"
        fi
    fi

    echo "N=$N physical_steps=$STEPS solver_calls=$SOLVER_CALLS total_work=$TOTAL_WORK status=$STATUS"
    cat "$SIGNATURE"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NODES" "$N" "$PPN" "$STEPS" "$FINAL_TIME" "$FINAL_DT" \
        "$SOLVER_CALLS" "$TOTAL_WORK" "$EXT" "$STATUS" "$RUN_DIR" \
        >> "$SUMMARY_FILE"

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$N" "$STEPS" "$SOLVER_CALLS" "$TOTAL_WORK" "$STATUS" \
        >> "$WORKLOAD_SUMMARY"
done

echo
echo "=================================================================="
echo "ALL PATO RUNS COMPLETED AND MATCHED"
echo "=================================================================="
echo "Runtime: $RUNTIME"
echo "Nodes: $NODES"
echo "Cells: $EXPECTED_CELLS"
echo "deltaT: $DELTA_T"
echo "endTime: $END_TIME"
echo "adjustTimeStep: $ADJUST_TIME_STEP"
echo "maxCo: $MAX_CO"
echo "steps: $EXPECTED_STEPS"
echo "motion sweeps: $MOTION_SWEEPS"
echo "p sweeps: $P_SWEEPS"
echo "Ta sweeps: $TA_SWEEPS"
echo "Xsi/Yi/Zi/rT sweeps: 1"
echo "Summary: $SUMMARY_FILE"
echo "Workload: $WORKLOAD_SUMMARY"
echo "Reference signature: $REFERENCE_SIGNATURE"
echo "=================================================================="

exit 0

