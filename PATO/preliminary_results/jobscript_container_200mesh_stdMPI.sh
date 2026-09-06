#!/bin/bash
#SBATCH --job-name=pato_8m_container_standard_mpi
#SBATCH --output=/beegfs/gopal/new/pato/logs/pato_8m_container_standard_mpi_%j.out
#SBATCH --error=/beegfs/gopal/new/pato/logs/pato_8m_container_standard_mpi_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

# Submit the same script for any supported node count:
# 1 node : sbatch --nodes=1 --ntasks=50  --ntasks-per-node=50 
# 2 nodes: sbatch --nodes=2 --ntasks=100 --ntasks-per-node=50 
# 4 nodes: sbatch --nodes=4 --ntasks=200 --ntasks-per-node=50 

BASE_DIR="/beegfs/gopal/new/pato"
IMAGE="${BASE_DIR}/pato_image.sif"
CASE_IN_IMAGE="/opt/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"
PATO_BIN="/opt/pato-3.1/install/bin/PATOx"
MODE="standard_mpi"
RUNTIME="container"

die() { echo "ERROR: $*" >&2; exit 1; }
require_file() { [ -f "$1" ] || die "Required file not found: $1"; }
require_dir() { [ -d "$1" ] || die "Required directory not found: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

show_failure_logs() {
    local out_file="$1"
    local err_file="$2"
    echo "---------------- stdout ----------------"
    [ -s "$out_file" ] && tail -n 200 "$out_file" || true
    echo "---------------- stderr ----------------"
    [ -s "$err_file" ] && tail -n 200 "$err_file" || true
    echo "----------------------------------------"
}

set_dictionary_entry() {
    local file="$1" key="$2" value="$3"
    python3 - "$file" "$key" "$value" <<'PYDICT'
from pathlib import Path
import re, sys
path=Path(sys.argv[1]); key=sys.argv[2]; value=sys.argv[3]
text=path.read_text()
pattern=rf"(?m)^[ \t]*{re.escape(key)}[ \t]+[^;]+;"
replacement=f"{key:<18}{value};"
text, count=re.subn(pattern,replacement,text,count=1)
if count == 0:
    text += f"\n{replacement}\n"
path.write_text(text)
PYDICT
}

set_m4_integer() {
    local file="$1" name="$2" value="$3"
    python3 - "$file" "$name" "$value" <<'PYM4'
from pathlib import Path
import re, sys
path=Path(sys.argv[1]); name=sys.argv[2]; value=sys.argv[3]
text=path.read_text()
patterns=[
 re.compile(rf"(?m)^([ \t]*define\([ \t]*{re.escape(name)}[ \t]*,[ \t]*)[-+]?[0-9]+([ \t]*\).*)$"),
 re.compile(rf"(?m)^([ \t]*define\([`'\"]{re.escape(name)}[`'\"][ \t]*,[ \t]*)[-+]?[0-9]+([ \t]*\).*)$"),
]
for pat in patterns:
    updated,count=pat.subn(rf"\g<1>{value}\g<2>",text,count=1)
    if count:
        path.write_text(updated)
        print(f"Updated {name}={value}")
        raise SystemExit(0)
raise SystemExit(f"Could not find define({name}, ...) in {path}")
PYM4
}

elapsed_seconds() {
    python3 - "$1" "$2" <<'PYTIME'
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PYTIME
}

REGION="porousMat"
EXPECTED_CELLS=8000000
MESH_NPS=64
MESH_NPD=34
MESH_NPY=625

# Corrected simulation settings: 0.075 / 0.00075 = exactly 100 steps.
DELTA_T="0.00075"
END_TIME="0.075"
NUMBER_OF_STEPS=100
WRITE_INTERVAL="$NUMBER_OF_STEPS"

MPI_PML="ob1"
MPI_BTL="self,vader,tcp"

NODES="${SLURM_JOB_NUM_NODES:-0}"
ALLOCATED_TASKS="${SLURM_NTASKS:-0}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"
JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

[ "$NODES" -gt 0 ] || die "Submit this script with sbatch."
[ "$ALLOCATED_TASKS" -gt 0 ] || die "SLURM_NTASKS is unavailable."

case "$NODES" in
    1) PROCS_LIST="2 4 8 16 24 32 40 50" ;;
    2) PROCS_LIST="2 4 8 16 32 50 64 80 100" ;;
    4) PROCS_LIST="4 8 16 32 64 100 128 160 200" ;;
    *) die "Only 1-, 2-, and 4-node jobs are supported." ;;
esac

EXPECTED_TASKS=$((NODES * 50))
[ "$ALLOCATED_TASKS" -ge "$EXPECTED_TASKS" ] ||
    die "Expected at least $EXPECTED_TASKS allocated tasks for $NODES nodes; received $ALLOCATED_TASKS."

for N in $PROCS_LIST; do
    [ "$N" -le "$ALLOCATED_TASKS" ] || die "$N ranks exceed allocation of $ALLOCATED_TASKS."
    if [ "$MODE" = "explicit_mpi" ]; then
        [ $((N % NODES)) -eq 0 ] || die "$N ranks cannot be balanced over $NODES nodes."
        PPN_CHECK=$((N / NODES))
        [ "$PPN_CHECK" -le "$TASKS_PER_NODE" ] || die "$N ranks require $PPN_CHECK ranks/node."
    fi
done

ROOT="${BASE_DIR}/results/ArcJet_cylinder_3D_8m_container_${NODES}node_${MODE}_${JOB_ID}"
BASE_CASE="$ROOT/base_case"; RUNS_DIR="$ROOT/runs"; LOGS_DIR="$ROOT/logs"
SUMMARY_FILE="$ROOT/timing_summary.tsv"
mkdir -p "$BASE_DIR/logs"; rm -rf "$ROOT"; mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS_DIR"
exec > >(stdbuf -oL -eL tee -a "$LOGS_DIR/console.log") 2>&1

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load M4 2>/dev/null || module load gm4 2>/dev/null || true
module list 2>&1 || true
export OMP_NUM_THREADS=1 OMP_PROC_BIND=false
unset OMP_PLACES || true
for c in gcc mpirun python3 m4 apptainer scontrol awk grep; do require_command "$c"; done
require_file "$IMAGE"

read -r -d '' CONTAINER_INIT <<'INNER' || true
set +e
set +u
set +o pipefail
[ -f /opt/host_mpi_env.sh ] || exit 10
. /opt/host_mpi_env.sh
MPI_ENV_RC=$?

export FOAM_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-7
export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-7
export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt
export PATO_DIR=/opt/pato-3.1
export PATO_BIN=/opt/pato-3.1/install/bin/PATOx

. /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
OPENFOAM_RC=$?
. /opt/pato-3.1/bashrc
PATO_RC=$?

set -e
set -o pipefail
export PATH="/opt/pato-3.1/install/bin:${PATH}"
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES FOAM_SIGFPE CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

[ "$MPI_ENV_RC" -eq 0 ] || exit 11
[ "$OPENFOAM_RC" -eq 0 ] || exit 11
[ "$PATO_RC" -eq 0 ] || exit 11
[ -x "$PATO_BIN" ] || exit 12
INNER


echo "============================================================"
echo "PATO 8M container benchmark"
echo "============================================================"
echo "Mode: $MODE | Nodes: $NODES | Ranks: $PROCS_LIST"
echo "Mesh: NPS=$MESH_NPS NPD=$MESH_NPD NPY=$MESH_NPY => $EXPECTED_CELLS cells"
echo "deltaT=$DELTA_T endTime=$END_TIME steps=$NUMBER_OF_STEPS"
echo "Results: $ROOT"

apptainer exec --cleanenv --bind /beegfs/Tools:/beegfs/Tools:ro "$IMAGE" /bin/bash -lc "${CONTAINER_INIT}; ldd '$PATO_BIN'; ! ldd '$PATO_BIN' | grep -q 'not found'" > "$LOGS_DIR/container_verification.log" 2>&1 || { cat "$LOGS_DIR/container_verification.log"; die "Container verification failed."; }
cat "$LOGS_DIR/container_verification.log"
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$LOGS_DIR/allocated_nodes.txt"

apptainer exec --cleanenv --bind /beegfs/Tools:/beegfs/Tools:ro --bind "$BASE_CASE:/case" "$IMAGE" /bin/bash -lc "set -e; cp -a '$CASE_IN_IMAGE/.' /case/"
CONTROL_DICT="$BASE_CASE/system/controlDict"; M4_FILE="$BASE_CASE/cylinderMesh.m4"
require_file "$CONTROL_DICT"; require_file "$M4_FILE"; require_dir "$BASE_CASE/origin.0"

set_dictionary_entry "$CONTROL_DICT" endTime "$END_TIME"
set_dictionary_entry "$CONTROL_DICT" deltaT "$DELTA_T"
set_dictionary_entry "$CONTROL_DICT" adjustTimeStep no
set_dictionary_entry "$CONTROL_DICT" writeControl timeStep
set_dictionary_entry "$CONTROL_DICT" writeInterval "$WRITE_INTERVAL"
set_dictionary_entry "$CONTROL_DICT" purgeWrite 1

set_m4_integer "$M4_FILE" NPS "$MESH_NPS"
set_m4_integer "$M4_FILE" NPD "$MESH_NPD"
set_m4_integer "$M4_FILE" NPY "$MESH_NPY"

mkdir -p "$BASE_CASE/constant/$REGION/polyMesh"
m4 "$M4_FILE" > "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"
grep -q 'changecom(' "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict" &&
    die "Generated blockMeshDict contains unexpanded m4 directives."

rm -rf "$BASE_CASE/0"
cp -a "$BASE_CASE/origin.0" "$BASE_CASE/0"
mkdir -p "$BASE_CASE/logs"

set +e
apptainer exec --cleanenv --bind /beegfs/Tools:/beegfs/Tools:ro --bind "$BASE_CASE:/case" --pwd /case "$IMAGE" /bin/bash -lc "${CONTAINER_INIT}; blockMesh -region '$REGION' > /case/logs/log.blockMesh.$REGION 2> /case/logs/err.blockMesh.$REGION; checkMesh -region '$REGION' > /case/logs/log.checkMesh.$REGION 2> /case/logs/err.checkMesh.$REGION"
MESH_RC=$?
set -e
[ "$MESH_RC" -eq 0 ] || die "blockMesh/checkMesh failed."
grep -q 'Mesh OK' "$BASE_CASE/logs/log.checkMesh.$REGION" || die "checkMesh did not report Mesh OK."
MESH_CELLS="$(awk '/nCells:/ {v=$2} /^[[:space:]]*cells:/ {v=$2} END {print v}' "$BASE_CASE/logs/log.blockMesh.$REGION" "$BASE_CASE/logs/log.checkMesh.$REGION")"
[ "$MESH_CELLS" -eq "$EXPECTED_CELLS" ] || die "Expected $EXPECTED_CELLS cells; detected $MESH_CELLS."
echo "Exact $MESH_CELLS-cell mesh confirmed."
cp -a "$BASE_CASE/logs" "$LOGS_DIR/base_mesh_logs"

printf 'mode\tallocated_nodes\tranks\tused_hosts\tactual_placement\tmesh_nps\tmesh_npd\tmesh_npy\tcells\tcells_per_rank\tmpi_pml\tmpi_btl\tmpi_mapping\tmpi_binding\tdecomposition\tdelta_t\tend_time\ttime_steps\telapsed_seconds\texit_code\tstatus\tcase_directory\n' > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    echo
    echo "============================================================"
    echo "Running PATO: runtime=$RUNTIME mode=$MODE nodes=$NODES ranks=$N"
    echo "============================================================"

    PPN=$((N / NODES))
    RUN_CASE="$RUNS_DIR/case_N${N}"
    RUN_LOG_DIR="$RUN_CASE/logs"
    rm -rf "$RUN_CASE"
    mkdir -p "$RUN_CASE"
    cp -a "$BASE_CASE/." "$RUN_CASE/"
    cd "$RUN_CASE"
    rm -rf processor* postProcessing logs 0
    mkdir -p "$RUN_LOG_DIR" "system/$REGION"
    cp -a origin.0 0

    cat > system/decomposeParDict <<DECOMP
FoamFile
{
    version 2.0;
    format ascii;
    class dictionary;
    location "system";
    object decomposeParDict;
}
numberOfSubdomains $N;
method scotch;
distributed no;
roots ();
DECOMP
    cp system/decomposeParDict "system/$REGION/decomposeParDict"

    set +e
    apptainer exec --cleanenv --bind /beegfs/Tools:/beegfs/Tools:ro --bind "$RUN_CASE:/case" --pwd /case "$IMAGE" /bin/bash -lc "${CONTAINER_INIT}; decomposePar -region '$REGION' > /case/logs/log.decompose.$REGION.$N 2> /case/logs/err.decompose.$REGION.$N"
    DECOMPOSE_RC=$?
    set -e
    [ "$DECOMPOSE_RC" -eq 0 ] || die "decomposePar failed for N=$N."
    PROCESSOR_COUNT="$(find "$RUN_CASE" -maxdepth 1 -type d -name 'processor[0-9]*' | wc -l | tr -d '[:space:]')"
    [ "$PROCESSOR_COUNT" -eq "$N" ] || die "Expected $N processor directories; found $PROCESSOR_COUNT."

    PLACEMENT_OUT="$RUN_LOG_DIR/rank_placement.${N}.out"
    PLACEMENT_ERR="$RUN_LOG_DIR/rank_placement.${N}.err"
    PLACEMENT_SUMMARY="$RUN_LOG_DIR/rank_placement_summary.${N}.txt"

    MPI_PLACE_ARGS=()
    if [ "$MODE" = "explicit_mpi" ]; then
        MPI_PLACE_ARGS=(--map-by "ppr:${PPN}:node:PE=1" --bind-to core --report-bindings)
    fi

    set +e
    mpirun --mca pml "$MPI_PML" --mca btl "$MPI_BTL" \
        "${MPI_PLACE_ARGS[@]}" -np "$N" hostname \
        > "$PLACEMENT_OUT" 2> "$PLACEMENT_ERR"
    PLACEMENT_RC=$?
    set -e
    [ "$PLACEMENT_RC" -eq 0 ] || {
        show_failure_logs "$PLACEMENT_OUT" "$PLACEMENT_ERR"
        die "Rank-placement test failed for N=$N."
    }

    sort "$PLACEMENT_OUT" | uniq -c | awk '{print $1, $2}' > "$PLACEMENT_SUMMARY"
    cat "$PLACEMENT_SUMMARY"
    PLACED_RANKS="$(awk '{sum+=$1} END {print sum+0}' "$PLACEMENT_SUMMARY")"
    [ "$PLACED_RANKS" -eq "$N" ] || die "Placement used $PLACED_RANKS ranks; expected $N."
    USED_HOSTS="$(awk '{print $2}' "$PLACEMENT_SUMMARY" | sort -u | wc -l | tr -d '[:space:]')"

    if [ "$MODE" = "explicit_mpi" ]; then
        [ "$USED_HOSTS" -eq "$NODES" ] || die "Explicit placement used $USED_HOSTS hosts; expected $NODES."
        while read -r rank_count node_name; do
            [ "$rank_count" -eq "$PPN" ] || die "$node_name received $rank_count ranks; expected $PPN."
        done < "$PLACEMENT_SUMMARY"
    fi

    ACTUAL_PLACEMENT="$(awk 'BEGIN{s=""} {printf "%s%s:%s",s,$2,$1;s=";"} END{print ""}' "$PLACEMENT_SUMMARY")"
    if [ "$MODE" = "explicit_mpi" ]; then
        MPI_MAPPING_VALUE="ppr:${PPN}:node:PE=1"
        MPI_BINDING_VALUE="core"
    else
        MPI_MAPPING_VALUE="OpenMPI-default"
        MPI_BINDING_VALUE="OpenMPI-default"
    fi

    SOLVER_LOG="$RUN_LOG_DIR/log.${N}proc"; SOLVER_ERR="$RUN_LOG_DIR/err.${N}proc"
    SOLVER_MPI_ARGS=()
    [ "$MODE" = "explicit_mpi" ] && SOLVER_MPI_ARGS=(--map-by "ppr:${PPN}:node:PE=1" --bind-to core)
    START_EPOCH="$(date +%s.%N)"
    set +e
    mpirun --mca pml "$MPI_PML" --mca btl "$MPI_BTL" "${SOLVER_MPI_ARGS[@]}" -np "$N" \
        apptainer exec --bind /beegfs/Tools:/beegfs/Tools:ro --bind "$RUN_CASE:/case" --pwd /case \
        --env OMP_NUM_THREADS=1 --env OMP_PROC_BIND=false "$IMAGE" /bin/bash -lc "${CONTAINER_INIT}; cd /case; exec '$PATO_BIN' -parallel -case /case" \
        > "$SOLVER_LOG" 2> "$SOLVER_ERR"
    SOLVER_RC=$?
    set -e

    END_EPOCH="$(date +%s.%N)"
    ELAPSED="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"
    CELLS_PER_RANK="$(awk -v c="$MESH_CELLS" -v r="$N" 'BEGIN{printf "%.3f",c/r}')"
    if [ "$SOLVER_RC" -eq 0 ]; then STATUS="completed"; else STATUS="failed"; fi

    {
        echo
        echo "============================================================"
        echo "PATO RUN SUMMARY"
        echo "============================================================"
        echo "Runtime:            $RUNTIME"
        echo "Mode:               $MODE"
        echo "Allocated nodes:    $NODES"
        echo "Used hosts:         $USED_HOSTS"
        echo "Actual placement:   $ACTUAL_PLACEMENT"
        echo "MPI ranks:          $N"
        echo "Mesh cells:         $MESH_CELLS"
        echo "Cells per rank:     $CELLS_PER_RANK"
        echo "deltaT:             $DELTA_T"
        echo "endTime:            $END_TIME"
        echo "Time steps:         $NUMBER_OF_STEPS"
        echo "MPI mapping:        $MPI_MAPPING_VALUE"
        echo "MPI binding:        $MPI_BINDING_VALUE"
        echo "Elapsed wall time:  $ELAPSED s"
        echo "Exit code:          $SOLVER_RC"
        echo "Status:             $STATUS"
        echo "============================================================"
    } | tee -a "$SOLVER_LOG"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$MODE" "$NODES" "$N" "$USED_HOSTS" "$ACTUAL_PLACEMENT" \
        "$MESH_NPS" "$MESH_NPD" "$MESH_NPY" "$MESH_CELLS" "$CELLS_PER_RANK" \
        "$MPI_PML" "$MPI_BTL" "$MPI_MAPPING_VALUE" "$MPI_BINDING_VALUE" scotch \
        "$DELTA_T" "$END_TIME" "$NUMBER_OF_STEPS" "$ELAPSED" "$SOLVER_RC" "$STATUS" "$RUN_CASE" \
        >> "$SUMMARY_FILE"

    cp -a "$RUN_LOG_DIR" "$LOGS_DIR/logs_N${N}"
    if [ "$SOLVER_RC" -ne 0 ]; then
        show_failure_logs "$SOLVER_LOG" "$SOLVER_ERR"
        die "PATOx failed for N=$N."
    fi
    if grep -Eiq 'FOAM FATAL|segmentation fault|(^|[^a-z])nan([^a-z]|$)' "$SOLVER_LOG" "$SOLVER_ERR"; then
        die "Fatal error, segmentation fault, or NaN detected for N=$N."
    fi
    echo "Completed N=$N in $ELAPSED seconds."
done

echo
echo "============================================================"
echo "All PATO runs completed"
echo "============================================================"
echo "Results directory: $ROOT"
echo "Timing summary:    $SUMMARY_FILE"
command -v column >/dev/null 2>&1 && column -t -s $'\t' "$SUMMARY_FILE" || cat "$SUMMARY_FILE"
echo "Finished: $(date)"

