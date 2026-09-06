#!/bin/bash
#SBATCH --job-name=openfoam_container_SMPI
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=2
#SBATCH --ntasks=100
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

PROJECT_ROOT="/beegfs/gopal/new/openfoam"
IMG="${PROJECT_ROOT}/openfoam_image.sif"

HOST_MPI_ENV="/opt/host_mpi_env.sh"
OF_ROOT="/opt/OpenFOAM/OpenFOAM-v2406"
OF_BASHRC="${OF_ROOT}/etc/bashrc"
CASE_IN_IMG="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"

NODES="${SLURM_JOB_NUM_NODES:-1}"
TASKS="${SLURM_NTASKS:-1}"
JOB_ID="${SLURM_JOB_ID:-manual}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"

if (( NODES < 1 || TASKS < 1 )); then
    echo "ERROR: Invalid Slurm allocation."
    exit 1
fi

if (( TASKS % NODES != 0 )); then
    echo "ERROR: ${TASKS} tasks cannot be distributed equally across ${NODES} nodes."
    exit 1
fi

ALLOCATED_TASKS_PER_NODE=$((TASKS / NODES))
MAX_RANKS_PER_NODE=50

RESULT_ROOT="${PROJECT_ROOT}/results"
CASE_ROOT="${RESULT_ROOT}/smallPoolFire3D_container_SMPI_${NODES}node_${JOB_ID}"
BASE_CASE="${CASE_ROOT}/base_case"
RUNS_DIR="${CASE_ROOT}/runs"
LOGS="${CASE_ROOT}/logs"

# Identical simulation parameters
MESH_X=80
MESH_Y=80
MESH_Z=80

DELTA_T="0.00075"
END_TIME="0.075"
ADJUST_TIME_STEP="no"
MAX_CO="0.45"

WRITE_CONTROL="timeStep"
WRITE_INTERVAL="100"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# Balanced processor lists
case "$NODES" in
    1)
        PROCS_LIST="2 4 8 10 16 20 25 32 40 50"
        ;;
    2)
        PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"
        ;;
    4)
        PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"
        ;;
    *)
        echo "ERROR: Only 1-, 2-, and 4-node runs are supported."
        exit 2
        ;;
esac

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"
exec > >(stdbuf -oL -eL tee -a "${LOGS}/console.log") 2>&1

echo "============================================================"
echo "OpenFOAM v2406 container benchmark"
echo "============================================================"
echo "Job ID:              ${JOB_ID}"
echo "Job name:            ${SLURM_JOB_NAME:-manual}"
echo "Nodes:               ${NODES}"
echo "Allocated tasks:     ${TASKS}"
echo "Tasks per node:      ${ALLOCATED_TASKS_PER_NODE}"
echo "CPUs per task:       ${CPUS_PER_TASK}"
echo "Processor list:      ${PROCS_LIST}"
echo "Container image:     ${IMG}"
echo "Case source:         ${CASE_IN_IMG}"
echo "Result directory:    ${CASE_ROOT}"
echo "Date:                $(date)"
echo "============================================================"

if [[ ! -f "$IMG" ]]; then
    echo "ERROR: Container image not found: ${IMG}"
    exit 3
fi

# Host modules
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

echo
echo "Loaded modules:"
module list 2>&1 || true

echo
echo "Compiler and MPI:"
gcc --version | sed -n '1p'
mpirun --version | sed -n '1p'

echo
echo "UCX support:"
ompi_info --param pml ucx --level 1

if ! ompi_info --param pml ucx --level 1 2>&1 | grep -q "MCA pml: ucx"; then
    echo "ERROR: OpenMPI UCX PML component is unavailable."
    exit 4
fi

scontrol show hostnames "${SLURM_JOB_NODELIST}" | tee "${LOGS}/nodes.txt"

CONTAINER_INIT="
    set -e
    set -o pipefail

    test -f '${HOST_MPI_ENV}'
    . '${HOST_MPI_ENV}'

    export FOAM_INST_DIR=/opt/OpenFOAM
    export WM_PROJECT_INST_DIR=/opt/OpenFOAM
    export WM_PROJECT_DIR='${OF_ROOT}'
    export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-v2406
    export WM_COMPILER_TYPE=system
    export WM_COMPILER=Gcc
    export WM_MPLIB=SYSTEMOPENMPI
    export WM_PRECISION_OPTION=DP
    export WM_LABEL_SIZE=32
    export WM_COMPILE_OPTION=Opt
    export FFTW_ARCH_PATH=/usr
    export SCOTCH_ARCH_PATH=/usr
    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close
    export OMP_PLACES=cores

    set +e
    set +u
    set +o pipefail
    . '${OF_BASHRC}'
    BASHRC_RC=\$?
    set -e
    set -o pipefail

    if [ \"\$BASHRC_RC\" -ne 0 ]; then
        echo \"ERROR: OpenFOAM bashrc returned \$BASHRC_RC\"
        exit \"\$BASHRC_RC\"
    fi

    # Restore the exact host MPI and dependency paths after OpenFOAM bashrc.
    . '${HOST_MPI_ENV}'

    unset CPATH
    unset C_INCLUDE_PATH
    unset CPLUS_INCLUDE_PATH
"

run_in_container()
{
    local CASE_DIR="$1"
    shift
    local COMMAND="$*"

    apptainer exec \
        --cleanenv \
        --bind /beegfs/Tools:/beegfs/Tools:ro \
        --bind "${CASE_DIR}:/case" \
        --pwd /case \
        --env OMP_NUM_THREADS=1 \
        --env OMP_PROC_BIND=close \
        --env OMP_PLACES=cores \
        "$IMG" \
        /bin/bash -lc "
            ${CONTAINER_INIT}
            cd /case
            ${COMMAND}
        "
}

# Validate the actual runtime, not only command availability
echo
echo "Validating OpenFOAM and host MPI runtime inside the image"

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMG" \
    /bin/bash -lc "
        ${CONTAINER_INIT}

        echo \"MPI_HOME=\${MPI_HOME:-unset}\"
        echo \"mpirun: \$(command -v mpirun)\"
        mpirun --version | sed -n '1p'

        echo \"blockMesh: \$(command -v blockMesh)\"
        echo \"fireFoam:  \$(command -v fireFoam)\"

        test -d '${CASE_IN_IMG}'

        MPI_LIB=\${MPI_HOME}/lib/libmpi.so.40
        test -e \"\$MPI_LIB\" || {
            echo \"ERROR: Expected MPI library is unavailable: \$MPI_LIB\"
            exit 20
        }

        echo \"MPI library: \$MPI_LIB\"

        # Execute a harmless OpenFOAM command to verify dynamic linkage.
        blockMesh -help >/tmp/blockMesh-help.txt 2>/tmp/blockMesh-help.err || {
            cat /tmp/blockMesh-help.err
            exit 21
        }

        fireFoam -help >/tmp/fireFoam-help.txt 2>/tmp/fireFoam-help.err || {
            cat /tmp/fireFoam-help.err
            exit 22
        }

        echo \"OpenFOAM runtime validation passed.\"
    "

# Copy tutorial
echo
echo "============================================================"
echo "Preparing common base case"
echo "============================================================"

rm -rf "${BASE_CASE:?}/"*

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    --bind "${BASE_CASE}:/case" \
    "$IMG" \
    /bin/bash -lc "
        ${CONTAINER_INIT}
        cp -a '${CASE_IN_IMG}/.' /case/
    "

for REQUIRED_PATH in \
    "${BASE_CASE}/system/blockMeshDict" \
    "${BASE_CASE}/system/controlDict" \
    "${BASE_CASE}/0.orig"
do
    if [[ ! -e "$REQUIRED_PATH" ]]; then
        echo "ERROR: Required case item was not copied: ${REQUIRED_PATH}"
        exit 5
    fi
done

# Mesh: 80 x 80 x 80 = 512,000 cells
echo "Updating mesh to ${MESH_X} x ${MESH_Y} x ${MESH_Z}"

if ! grep -Eq '\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)' \
    "${BASE_CASE}/system/blockMeshDict"; then
    echo "ERROR: Original 60 x 60 x 60 mesh entry was not found."
    exit 6
fi

sed -Ei \
    "s/\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)/(${MESH_X} ${MESH_Y} ${MESH_Z})/" \
    "${BASE_CASE}/system/blockMeshDict"

# controlDict: 100 fixed steps
set_dict_entry()
{
    local FILE="$1"
    local KEY="$2"
    local VALUE="$3"

    if grep -Eq "^[[:space:]]*${KEY}[[:space:]]+" "$FILE"; then
        sed -Ei \
            "s|^[[:space:]]*${KEY}[[:space:]]+[^;]*;|${KEY}    ${VALUE};|" \
            "$FILE"
    else
        echo "ERROR: ${KEY} was not found in ${FILE}"
        exit 7
    fi
}

CONTROL_DICT="${BASE_CASE}/system/controlDict"

set_dict_entry "$CONTROL_DICT" deltaT "$DELTA_T"
set_dict_entry "$CONTROL_DICT" endTime "$END_TIME"
set_dict_entry "$CONTROL_DICT" adjustTimeStep "$ADJUST_TIME_STEP"
set_dict_entry "$CONTROL_DICT" maxCo "$MAX_CO"
set_dict_entry "$CONTROL_DICT" writeControl "$WRITE_CONTROL"
set_dict_entry "$CONTROL_DICT" writeInterval "$WRITE_INTERVAL"

# Identical function objects
sed -i '/^[[:space:]]*functions[[:space:]]*$/,$d' "$CONTROL_DICT"

cat >> "$CONTROL_DICT" <<'EOF'

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

# Identical fvSolution settings
cat > "${BASE_CASE}/system/fvSolution" <<'EOF'
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
        solver          PCG;
        preconditioner  DIC;
        tolerance       1e-6;
        relTol          0;
        minIter         0;
        maxIter         0;
    }

    p_rgh
    {
        solver          GAMG;
        tolerance       1e-6;
        relTol          0.1;
        smoother        GaussSeidel;
        minIter         2;
        maxIter         2;
    }

    p_rghFinal
    {
        $p_rgh;
        tolerance       1e-6;
        relTol          0;
        minIter         2;
        maxIter         2;
    }

    ph_rgh
    {
        $p_rgh;
        minIter         2;
        maxIter         2;
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
    }

    "(U|Yi|k|h)Final"
    {
        $U;
        tolerance       1e-6;
        relTol          0;
        minIter         1;
        maxIter         1;
    }

    Ii
    {
        solver          GAMG;
        tolerance       1e-4;
        relTol          0;
        smoother        symGaussSeidel;
        minIter         1;
        maxIter         1;
        nPostSweeps     1;
    }

    G
    {
        solver          PCG;
        preconditioner  DIC;
        tolerance       1e-4;
        relTol          0;
        minIter         1;
        maxIter         1;
    }
}

PIMPLE
{
    momentumPredictor           yes;
    nOuterCorrectors            1;
    nCorrectors                 2;
    nNonOrthogonalCorrectors    0;
    hydrostaticInitialization   yes;
    nHydrostaticCorrectors      5;
}

relaxationFactors
{
    equations
    {
        "(U|k).*"                    1;
        "(CH4|O2|H2O|CO2|h).*"      1;
    }
}
EOF

# Build and verify the common mesh
rm -rf "${BASE_CASE}/processor"* \
       "${BASE_CASE}/constant/polyMesh" \
       "${BASE_CASE}/0"

cp -a "${BASE_CASE}/0.orig" "${BASE_CASE}/0"

echo "Running blockMesh"
run_in_container "$BASE_CASE" \
    "blockMesh > /case/log.blockMesh 2> /case/err.blockMesh"

mv "${BASE_CASE}/log.blockMesh" "${LOGS}/log.blockMesh"
mv "${BASE_CASE}/err.blockMesh" "${LOGS}/err.blockMesh"

echo "Running checkMesh"
run_in_container "$BASE_CASE" \
    "checkMesh > /case/log.checkMesh 2> /case/err.checkMesh"

mv "${BASE_CASE}/log.checkMesh" "${LOGS}/log.checkMesh"
mv "${BASE_CASE}/err.checkMesh" "${LOGS}/err.checkMesh"

if ! grep -q "Mesh OK" "${LOGS}/log.checkMesh"; then
    echo "ERROR: checkMesh did not report 'Mesh OK'."
    tail -n 100 "${LOGS}/log.checkMesh" || true
    tail -n 100 "${LOGS}/err.checkMesh" || true
    exit 8
fi

echo
echo "Fixed simulation configuration"
echo "------------------------------------------------------------"
echo "Mesh:                  ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
echo "Cells:                 $((MESH_X * MESH_Y * MESH_Z))"
echo "Solver:                fireFoam"
echo "deltaT:                ${DELTA_T} s"
echo "endTime:               ${END_TIME} s"
echo "adjustTimeStep:        ${ADJUST_TIME_STEP}"
echo "maxCo:                 ${MAX_CO}"
echo "Expected time steps:   100"
echo "Pressure iterations:   2"
echo "U/Yi/h/k iterations:   1"
echo "Radiation iterations:  1"
echo "PIMPLE outer:          1"
echo "PIMPLE correctors:     2"
echo "------------------------------------------------------------"

# Hierarchical layouts
get_layout()
{
    case "$1" in
        2)   echo "2 1 1" ;;
        4)   echo "2 2 1" ;;
        8)   echo "2 2 2" ;;
        10)  echo "5 2 1" ;;
        16)  echo "4 2 2" ;;
        20)  echo "5 2 2" ;;
        25)  echo "5 5 1" ;;
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

# Processor sweep
SUMMARY_FILE="${LOGS}/timing_summary.tsv"
printf "nodes\tranks\tranks_per_node\tdecomposition\telapsed_seconds\texit_code\n" \
    > "$SUMMARY_FILE"

for N in $PROCS_LIST
do
    echo
    echo "============================================================"
    echo "RUN: nodes=${NODES}, ranks=${N}"
    echo "============================================================"

    if (( N % NODES != 0 )); then
        echo "ERROR: ${N} ranks cannot be balanced across ${NODES} nodes."
        exit 9
    fi

    PPN=$((N / NODES))

    if (( PPN > MAX_RANKS_PER_NODE )); then
        echo "ERROR: ${PPN} ranks/node exceeds ${MAX_RANKS_PER_NODE}."
        exit 10
    fi

    if (( N > TASKS )); then
        echo "ERROR: ${N} ranks exceeds the ${TASKS}-task allocation."
        exit 11
    fi

    if ! read -r NX NY NZ < <(get_layout "$N"); then
        echo "ERROR: No hierarchical layout is defined for N=${N}."
        exit 12
    fi

    if (( NX * NY * NZ != N )); then
        echo "ERROR: Invalid layout ${NX} x ${NY} x ${NZ} for N=${N}."
        exit 13
    fi

    RUN_DIR="${RUNS_DIR}/${N}proc"
    RUN_LOG="${LOGS}/log.${N}proc"
    RUN_ERR="${LOGS}/err.${N}proc"
    DECOMP_LOG="${LOGS}/log.decompose.${N}"
    DECOMP_ERR="${LOGS}/err.decompose.${N}"

    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    cp -a "${BASE_CASE}/." "$RUN_DIR/"

    rm -rf "${RUN_DIR}/processor"* "${RUN_DIR}/0"
    cp -a "${RUN_DIR}/0.orig" "${RUN_DIR}/0"

    cat > "${RUN_DIR}/system/decomposeParDict" <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${N};

method hierarchical;

hierarchicalCoeffs
{
    n       (${NX} ${NY} ${NZ});
    delta   0.001;
    order   xyz;
}
EOF

    echo "Running decomposePar for N=${N}"
    run_in_container "$RUN_DIR" \
        "decomposePar -force > /case/log.decompose 2> /case/err.decompose"

    mv "${RUN_DIR}/log.decompose" "$DECOMP_LOG"
    mv "${RUN_DIR}/err.decompose" "$DECOMP_ERR"

    echo "Nodes:              ${NODES}"
    echo "MPI ranks:          ${N}"
    echo "Ranks per node:     ${PPN}"
    echo "Decomposition:      ${NX} x ${NY} x ${NZ}"
    echo "OpenMP threads:     1"
    echo "MPI PML:            UCX"
    echo "Binding:            one core per rank"

    START_NS="$(date +%s%N)"

    set +e

    mpirun \
        --mca pml ob1 \
        --mca btl self,vader,tcp \
        -np "$N" \
        apptainer exec \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${RUN_DIR}:/case" \
            --pwd /case \
            --env OMP_NUM_THREADS=1 \
            --env OMP_PROC_BIND=close \
            --env OMP_PLACES=cores \
            "$IMG" \
            /bin/bash -lc "
                ${CONTAINER_INIT}
                cd /case
                exec fireFoam -parallel -case /case
            " \
        > "$RUN_LOG" \
        2> "$RUN_ERR"

    RUN_RC=$?
    set -e

    END_NS="$(date +%s%N)"

    ELAPSED="$(
        awk -v TSTART="$START_NS" -v TEND="$END_NS" \
            'BEGIN {
		printf "%.6f", (TEND-TSTART)/1000000000
	    }'
    )"

    {
        echo
        echo "============================================================"
        echo "Timing and configuration"
        echo "============================================================"
        echo "Nodes:                 ${NODES}"
        echo "MPI ranks:             ${N}"
        echo "Ranks per node:        ${PPN}"
        echo "Decomposition:         ${NX} x ${NY} x ${NZ}"
        echo "External elapsed time: ${ELAPSED} s"
        echo "Exit code:             ${RUN_RC}"
        echo "============================================================"
    } >> "$RUN_LOG"

    printf "%s\t%s\t%s\t%sx%sx%s\t%s\t%s\n" \
        "$NODES" "$N" "$PPN" "$NX" "$NY" "$NZ" "$ELAPSED" "$RUN_RC" \
        >> "$SUMMARY_FILE"

    if (( RUN_RC != 0 )); then
        echo "ERROR: fireFoam failed for N=${N}, exit code ${RUN_RC}."
        echo "Output: ${RUN_LOG}"
        echo "Error:  ${RUN_ERR}"
        tail -n 80 "$RUN_LOG" || true
        tail -n 80 "$RUN_ERR" || true
        exit "$RUN_RC"
    fi

    if ! grep -q "^End$" "$RUN_LOG"; then
        echo "ERROR: OpenFOAM completion marker was not found for N=${N}."
        tail -n 100 "$RUN_LOG" || true
        exit 14
    fi

    echo "COMPLETED: N=${N}, elapsed=${ELAPSED} s"
done

echo
echo "============================================================"
echo "ALL OPENFOAM RUNS COMPLETED"
echo "============================================================"
echo "Summary:  ${SUMMARY_FILE}"
echo "Results:  ${CASE_ROOT}"
echo "Finished: $(date)"
echo "============================================================"

exit 0

