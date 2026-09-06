#!/bin/bash
#SBATCH --job-name=fds_h_200_exp_2n
#SBATCH --output=/beegfs/gopal/new/fds/host/logs/fds_h_200_exp_2n_%j.out
#SBATCH --error=/beegfs/gopal/new/fds/host/logs/fds_h_200_exp_2n_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=2
#SBATCH --ntasks=100
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -euo pipefail

BASE_DIR="/beegfs/gopal/new/fds/host"
FDS_BIN="${BASE_DIR}/bin/fds"
CASE_SRC="${BASE_DIR}/fds/Verification/Fires/spray_burner.fds"

MODE="explicit_mpi"
EXPECTED_NODES=2
EXPECTED_TASKS=100
PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"

TOTAL_I=200
TOTAL_J=200
TOTAL_K=200
TOTAL_CELLS=$((TOTAL_I * TOTAL_J * TOTAL_K))
T_END_VALUE="2.6"

MPI_PML="ob1"
MPI_BTL="self,vader,tcp"

JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
ROOT="${BASE_DIR}/results/spray_burner_200x200x200_host_2node_${MODE}_${JOB_ID}"
BASE_CASE_DIR="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"

mkdir -p "${BASE_DIR}/logs" "$BASE_CASE_DIR" "$RUNS_DIR" "$LOGS_DIR"
exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

timestamp() { date '+%Y-%m-%d %H:%M:%S %Z'; }
section() { echo; echo '============================================================'; echo "$*"; echo '============================================================'; }
die() { echo "ERROR: $*" >&2; exit 1; }
show_tail() { local f="$1"; [[ -f "$f" ]] && tail -n 200 "$f" || true; }
elapsed_seconds() { python3 - "$1" "$2" <<'PYTIME'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.6f}")
PYTIME
}

layout_for_ranks() {
    case "$1" in
        2)   echo "2 1 1" ;;
        4)   echo "2 2 1" ;;
        8)   echo "2 2 2" ;;
        10)  echo "5 2 1" ;;
        16)  echo "4 2 2" ;;
        20)  echo "5 2 2" ;;
        32)  echo "4 4 2" ;;
        40)  echo "5 4 2" ;;
        50)  echo "5 5 2" ;;
        64)  echo "4 4 4" ;;
        80)  echo "5 4 4" ;;
        100) echo "5 5 4" ;;
        128) echo "8 4 4" ;;
        160) echo "8 5 4" ;;
        200) echo "10 5 4" ;;
        *) return 1 ;;
    esac
}

[[ -n "${SLURM_JOB_ID:-}" ]] || die "Submit this script with sbatch."
[[ "${SLURM_JOB_NUM_NODES:-0}" -eq "$EXPECTED_NODES" ]] || die "Expected $EXPECTED_NODES nodes; received ${SLURM_JOB_NUM_NODES:-0}."
[[ "${SLURM_NTASKS:-0}" -ge "$EXPECTED_TASKS" ]] || die "Expected at least $EXPECTED_TASKS tasks; received ${SLURM_NTASKS:-0}."
[[ -x "$FDS_BIN" ]] || die "FDS executable missing: $FDS_BIN"
[[ -f "$CASE_SRC" ]] || die "Tutorial missing: $CASE_SRC"

for variable in OPAL_PREFIX OMPI_HOME MPI_HOME OMPI_MCA_pml OMPI_MCA_btl OMPI_MCA_rmaps_base_mapping_policy OMPI_MCA_hwloc_base_binding_policy; do
    unset "$variable" || true
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module list 2>&1 || true

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES || true

for cmd in mpirun python3 scontrol awk grep sed sort uniq wc ldd; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

case "$(mpirun --version | sed -n '1p')" in *4.1.5*) ;; *) die "Open MPI 4.1.5 is not active." ;; esac
MPI_LIBRARY="$(ldd "$FDS_BIN" | awk '/libmpi\.so/ {print $3; exit}')"
case "${MPI_LIBRARY:-}" in /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0/*) ;; *) die "Unexpected MPI library: ${MPI_LIBRARY:-not-found}" ;; esac

"$FDS_BIN" -v 2>&1 | tee "${LOGS_DIR}/fds_version.log"
"$FDS_BIN" -v 2>&1 | grep -q 'Open MPI v4.1.5' || die "FDS does not report Open MPI v4.1.5."

section "FDS HOST 200x200x200 — $MODE — $EXPECTED_NODES NODE(S)"
echo "Started:            $(timestamp)"
echo "Allocated nodes:    $EXPECTED_NODES"
echo "Allocated tasks:    $SLURM_NTASKS"
echo "Processor sweep:    $PROCS_LIST"
echo "Global mesh:        $TOTAL_I x $TOTAL_J x $TOTAL_K"
echo "Total cells:        $TOTAL_CELLS"
echo "Number of meshes:   MPI rank count"
echo "T_END:              $T_END_VALUE"
echo "MPI PML/BTL:        $MPI_PML / $MPI_BTL"
echo "MPI placement:      ppr:<ranks-per-node>:node:PE=1 / core"
echo "Results:            $ROOT"
scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "${LOGS_DIR}/allocated_nodes.txt"
cp "$CASE_SRC" "${BASE_CASE_DIR}/spray_burner_original.fds"

printf 'mode	allocated_nodes	ranks	ranks_per_node	used_hosts	actual_placement	total_i	total_j	total_k	total_cells	meshes	mesh_layout	local_i	local_j	local_k	cells_per_rank	t_end	final_step	final_time	fds_step_time_s	fds_total_time_s	external_time_s	return_code	status	run_directory
' > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    section "RUN N=$N"
    (( N <= SLURM_NTASKS )) || die "N=$N exceeds allocation."
    read -r NX NY NZ <<< "$(layout_for_ranks "$N")" || die "No layout for N=$N."
    (( NX * NY * NZ == N )) || die "Invalid layout for N=$N."
    (( TOTAL_I % NX == 0 && TOTAL_J % NY == 0 && TOTAL_K % NZ == 0 )) || die "200x200x200 is not divisible by ${NX}x${NY}x${NZ}."

    if [[ "$MODE" == "explicit_mpi" ]]; then
        (( N % EXPECTED_NODES == 0 )) || die "Explicit MPI requires N=$N divisible by $EXPECTED_NODES nodes."
        PPN=$((N / EXPECTED_NODES))
        (( PPN <= 50 )) || die "$PPN ranks/node exceeds 50."
    else
        PPN="NA"
    fi

    RUN_DIR="${RUNS_DIR}/case_N${N}"
    WORK_DIR="${RUN_DIR}/work"
    RUN_LOG_DIR="${RUN_DIR}/logs"
    CASE_FILE="spray_burner_${TOTAL_I}x${TOTAL_J}x${TOTAL_K}_${N}proc.fds"
    CASE_PATH="${WORK_DIR}/${CASE_FILE}"
    CASE_BASE="${CASE_FILE%.fds}"
    FDS_OUT="${WORK_DIR}/${CASE_BASE}.out"

    rm -rf "$RUN_DIR"
    mkdir -p "$WORK_DIR" "$RUN_LOG_DIR"
    cp "${BASE_CASE_DIR}/spray_burner_original.fds" "$CASE_PATH"

    python3 - "$CASE_PATH" "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" "$NX" "$NY" "$NZ" "$N" "$T_END_VALUE" <<'PYCASE'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); I,J,K=map(int,sys.argv[2:5]); nx,ny,nz=map(int,sys.argv[5:8]); expected=int(sys.argv[8]); t_end=sys.argv[9]
text=p.read_text()
pat=re.compile(r"(?ims)^[ \t]*&MESH\b.*?/[ \t]*(?:\r?\n|$)")
ms=list(pat.finditer(text))
if not ms: raise SystemExit("No original &MESH entry found")
first=ms[0].group(0)
xb=re.search(r"(?i)\bXB\s*=\s*([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)", first)
if not xb: raise SystemExit("Cannot extract XB from original mesh")
f=lambda s: float(s.replace('D','E').replace('d','e'))
x0,x1,y0,y1,z0,z1=map(f,xb.groups())
if nx*ny*nz != expected: raise SystemExit("Layout does not equal rank count")
if I%nx or J%ny or K%nz: raise SystemExit("Grid is not divisible by layout")
ii,jj,kk=I//nx,J//ny,K//nz
lines=[]
for ix in range(nx):
    xa=x0+(x1-x0)*ix/nx; xb2=x0+(x1-x0)*(ix+1)/nx
    for iy in range(ny):
        ya=y0+(y1-y0)*iy/ny; yb=y0+(y1-y0)*(iy+1)/ny
        for iz in range(nz):
            za=z0+(z1-z0)*iz/nz; zb=z0+(z1-z0)*(iz+1)/nz
            lines.append(f"&MESH IJK={ii},{jj},{kk}, XB={xa:.12g},{xb2:.12g},{ya:.12g},{yb:.12g},{za:.12g},{zb:.12g} /")
start,end=ms[0].span()
text=text[:start]+"\n".join(lines)+"\n"+pat.sub("",text[end:])
tpat=re.compile(r"(?ims)^[ \t]*&TIME\b.*?/[ \t]*(?:\r?\n|$)")
new=f"&TIME T_END={t_end} /\n"
text=tpat.sub(new,text,count=1) if tpat.search(text) else text+"\n"+new
p.write_text(text)
print(f"Generated {len(lines)} meshes")
print(f"Layout: {nx}x{ny}x{nz}")
print(f"Cells per mesh: {ii}x{jj}x{kk}")
print(f"Domain: {x0}, {x1}, {y0}, {y1}, {z0}, {z1}")
PYCASE

    MESH_COUNT="$(grep -ic '^[[:space:]]*&MESH' "$CASE_PATH" || true)"
    [[ "$MESH_COUNT" -eq "$N" ]] || die "Expected $N meshes; found $MESH_COUNT."
    LOCAL_I=$((TOTAL_I / NX)); LOCAL_J=$((TOTAL_J / NY)); LOCAL_K=$((TOTAL_K / NZ))
    CELLS_PER_RANK=$((LOCAL_I * LOCAL_J * LOCAL_K))
    VERIFIED_TOTAL=$((MESH_COUNT * CELLS_PER_RANK))
    [[ "$VERIFIED_TOTAL" -eq "$TOTAL_CELLS" ]] || die "Cell count mismatch: $VERIFIED_TOTAL."
    grep -i '^[[:space:]]*&MESH' "$CASE_PATH" > "${RUN_LOG_DIR}/generated_meshes.txt"
    grep -i '^[[:space:]]*&TIME' "$CASE_PATH" | tee "${RUN_LOG_DIR}/time_setting.txt"

    MPI_PLACE_ARGS=()
    if [[ "$MODE" == "explicit_mpi" ]]; then
        MPI_PLACE_ARGS=(--map-by "ppr:${PPN}:node:PE=1" --bind-to core)
    fi

    PLACEMENT_RAW="${RUN_LOG_DIR}/placement_raw.txt"
    PLACEMENT_ERR="${RUN_LOG_DIR}/placement.err"
    PLACEMENT_SUMMARY="${RUN_LOG_DIR}/placement_summary.txt"
    set +e
    mpirun --mca pml "$MPI_PML" --mca btl "$MPI_BTL" "${MPI_PLACE_ARGS[@]}" -np "$N" hostname > "$PLACEMENT_RAW" 2> "$PLACEMENT_ERR"
    PLACEMENT_RC=$?
    set -e
    [[ "$PLACEMENT_RC" -eq 0 ]] || { show_tail "$PLACEMENT_ERR"; die "Placement test failed for N=$N."; }
    sort "$PLACEMENT_RAW" | uniq -c | awk '{print $1, $2}' | tee "$PLACEMENT_SUMMARY"
    PLACED_RANKS="$(awk '{s+=$1} END {print s+0}' "$PLACEMENT_SUMMARY")"
    [[ "$PLACED_RANKS" -eq "$N" ]] || die "Placement found $PLACED_RANKS ranks instead of $N."
    USED_HOSTS="$(awk '{print $2}' "$PLACEMENT_SUMMARY" | sort -u | wc -l | tr -d '[:space:]')"
    ACTUAL_PLACEMENT="$(awk 'BEGIN{sep=""} {printf "%s%s:%s",sep,$2,$1;sep=";"} END{print ""}' "$PLACEMENT_SUMMARY")"

    if [[ "$MODE" == "explicit_mpi" ]]; then
        [[ "$USED_HOSTS" -eq "$EXPECTED_NODES" ]] || die "Explicit MPI used $USED_HOSTS hosts; expected $EXPECTED_NODES."
        while read -r count host; do [[ "$count" -eq "$PPN" ]] || die "$host has $count ranks; expected $PPN."; done < "$PLACEMENT_SUMMARY"
    fi

    MAIN_LOG="${RUN_LOG_DIR}/log.${N}proc"
    ERR_LOG="${RUN_LOG_DIR}/err.${N}proc"
    START_EPOCH="$(date +%s.%N)"; START_TEXT="$(timestamp)"
    set +e
    (cd "$WORK_DIR" && mpirun --mca pml "$MPI_PML" --mca btl "$MPI_BTL" "${MPI_PLACE_ARGS[@]}" -np "$N" "$FDS_BIN" "$CASE_FILE") > "$MAIN_LOG" 2> "$ERR_LOG"
    RC=$?
    set -e
    END_EPOCH="$(date +%s.%N)"; END_TEXT="$(timestamp)"
    EXTERNAL_TIME="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"

    STATUS="failed"; FINAL_STEP="NA"; FINAL_TIME="NA"; FDS_STEP_TIME="NA"; FDS_TOTAL_TIME="NA"
    if [[ "$RC" -eq 0 ]] && grep -Eq 'STOP: FDS completed successfully' "$MAIN_LOG" "$ERR_LOG"; then STATUS="completed"; fi
    FINAL_RECORD="$(grep -h 'Time Step:' "$MAIN_LOG" "$ERR_LOG" | tail -n 1 || true)"
    if [[ -n "$FINAL_RECORD" ]]; then
        FINAL_STEP="$(printf '%s
' "$FINAL_RECORD" | awk '{gsub(",","",$3); print $3}')"
        FINAL_TIME="$(printf '%s
' "$FINAL_RECORD" | awk '{print $6}')"
    fi
    if [[ -f "$FDS_OUT" ]]; then
        FDS_STEP_TIME="$(sed -n 's/.*Time Stepping Wall Clock Time (s):[[:space:]]*//p' "$FDS_OUT" | tail -n 1)"
        FDS_TOTAL_TIME="$(sed -n 's/.*Total Elapsed Wall Clock Time (s):[[:space:]]*//p' "$FDS_OUT" | tail -n 1)"
        [[ -n "$FDS_STEP_TIME" ]] || FDS_STEP_TIME="NA"
        [[ -n "$FDS_TOTAL_TIME" ]] || FDS_TOTAL_TIME="NA"
    fi

    {
      echo; echo '============================================================'; echo 'FDS RUN SUMMARY'; echo '============================================================'
      echo "Mode:                $MODE"; echo "Allocated nodes:     $EXPECTED_NODES"; echo "Used hosts:          $USED_HOSTS"; echo "Actual placement:    $ACTUAL_PLACEMENT"
      echo "MPI ranks:           $N"; echo "Ranks per node:      $PPN"; echo "Mesh layout:         ${NX}x${NY}x${NZ}"; echo "Local mesh:          ${LOCAL_I}x${LOCAL_J}x${LOCAL_K}"
      echo "Meshes:              $MESH_COUNT"; echo "Global grid:         ${TOTAL_I}x${TOTAL_J}x${TOTAL_K}"; echo "Total cells:         $TOTAL_CELLS"; echo "Cells per rank:      $CELLS_PER_RANK"
      echo "T_END:               $T_END_VALUE"; echo "Final step:          $FINAL_STEP"; echo "Final time:          $FINAL_TIME"
      echo "FDS step time:       $FDS_STEP_TIME s"; echo "FDS total time:      $FDS_TOTAL_TIME s"; echo "External time:       $EXTERNAL_TIME s"
      echo "Exit code:           $RC"; echo "Status:              $STATUS"; echo "Start:               $START_TEXT"; echo "End:                 $END_TEXT"; echo '============================================================'
    } | tee -a "$MAIN_LOG"

    printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s
'       "$MODE" "$EXPECTED_NODES" "$N" "$PPN" "$USED_HOSTS" "$ACTUAL_PLACEMENT" "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" "$TOTAL_CELLS"       "$MESH_COUNT" "${NX}x${NY}x${NZ}" "$LOCAL_I" "$LOCAL_J" "$LOCAL_K" "$CELLS_PER_RANK" "$T_END_VALUE" "$FINAL_STEP" "$FINAL_TIME"       "$FDS_STEP_TIME" "$FDS_TOTAL_TIME" "$EXTERNAL_TIME" "$RC" "$STATUS" "$RUN_DIR" >> "$SUMMARY_FILE"

    if [[ "$STATUS" != "completed" ]]; then show_tail "$MAIN_LOG"; show_tail "$ERR_LOG"; show_tail "$FDS_OUT"; die "FDS failed for N=$N."; fi
    echo "DONE N=$N | used_hosts=$USED_HOSTS | FDS total=${FDS_TOTAL_TIME} s | external=${EXTERNAL_TIME} s"
done

section "ALL FDS HOST RUNS COMPLETED"
column -t -s $'	' "$SUMMARY_FILE" 2>/dev/null || cat "$SUMMARY_FILE"
echo "Results:  $ROOT"
echo "Summary:  $SUMMARY_FILE"
echo "Finished: $(timestamp)"

