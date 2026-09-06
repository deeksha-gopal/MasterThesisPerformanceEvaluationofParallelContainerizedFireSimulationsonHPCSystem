#!/bin/bash
#SBATCH --job-name=openfoam_v2406_build
#SBATCH --output=openfoam_build_%j.out
#SBATCH --error=openfoam_build_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --exclusive

set -euo pipefail

BASE_DIR="/beegfs/gopal/new/openfoam"
DEF_FILE="${BASE_DIR}/openfoam_build.def"
IMAGE="${BASE_DIR}/openfoam_image.sif"
ENV_FILE="${BASE_DIR}/host_mpi_env.sh"
UCX_INFO_FILE="${BASE_DIR}/host_openmpi_ucx.txt"
LOG_DIR="${BASE_DIR}/logs"
BUILD_LOG="${LOG_DIR}/openfoam-v2406-build.log"
ERROR_LOG="${LOG_DIR}/openfoam-v2406-errors.log"
APPTAINER_TMPDIR="${BASE_DIR}/apptainer_tmp"
APPTAINER_CACHEDIR="${BASE_DIR}/apptainer_cache"
NBUILD="${SLURM_CPUS_PER_TASK:-4}"

cd "$BASE_DIR"
mkdir -p "$LOG_DIR" "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR"

export APPTAINER_TMPDIR
export APPTAINER_CACHEDIR
export APPTAINER_BUILD_CPUS="$NBUILD"

test -f "$DEF_FILE" || {
    echo "ERROR: Definition file not found: $DEF_FILE"
    exit 1
}

test -w "$LOG_DIR" || {
    echo "ERROR: Log directory is not writable: $LOG_DIR"
    exit 2
}

for variable_name in \
    FOAM_INST_DIR WM_PROJECT_INST_DIR WM_PROJECT_DIR WM_THIRD_PARTY_DIR \
    WM_PROJECT_VERSION WM_OPTIONS WM_COMPILER WM_COMPILER_TYPE WM_MPLIB \
    WM_PRECISION_OPTION WM_LABEL_SIZE WM_COMPILE_OPTION WM_NCOMPPROCS \
    FOAM_MPI FOAM_APPBIN FOAM_LIBBIN FOAM_USER_APPBIN FOAM_USER_LIBBIN \
    FOAM_SRC FFTW_ARCH_PATH SCOTCH_ARCH_PATH CPATH C_INCLUDE_PATH \
    CPLUS_INCLUDE_PATH
do
    unset "$variable_name" || true
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

module list 2>&1 || true

for command_name in gcc g++ gfortran mpicc mpicxx mpifort mpirun ompi_info apptainer
do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: $command_name is unavailable."
        exit 10
    }
done

case "$(gcc -dumpfullversion)" in
    12.3.0*) ;;
    *)
        echo "ERROR: GCC 12.3.0 is not active."
        exit 11
        ;;
esac

case "$(mpirun --version | sed -n '1p')" in
    *4.1.5*) ;;
    *)
        echo "ERROR: OpenMPI 4.1.5 is not active."
        exit 12
        ;;
esac

MPI_HOME="$(dirname "$(dirname "$(command -v mpirun)")")"

case "$MPI_HOME" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0) ;;
    *)
        echo "ERROR: Unexpected OpenMPI installation: $MPI_HOME"
        exit 13
        ;;
esac

ompi_info --param pml ucx --level 1 >"$UCX_INFO_FILE" 2>&1 || true
cat "$UCX_INFO_FILE"

grep -q "MCA pml: ucx" "$UCX_INFO_FILE" || {
    echo "ERROR: OpenMPI UCX PML is unavailable."
    exit 14
}

clean_beegfs_paths()
{
    local value="${1:-}"
    [[ -n "$value" ]] || return 0

    printf '%s\n' "$value" |
        tr ':' '\n' |
        awk '/^\/beegfs\/Tools\// {if (!seen[$0]++) print $0}' |
        paste -sd ':' -
}

CLEAN_PATH="$(clean_beegfs_paths "${PATH:-}")"
CLEAN_LD_LIBRARY_PATH="$(clean_beegfs_paths "${LD_LIBRARY_PATH:-}")"
CLEAN_LIBRARY_PATH="$(clean_beegfs_paths "${LIBRARY_PATH:-}")"
CLEAN_PKG_CONFIG_PATH="$(clean_beegfs_paths "${PKG_CONFIG_PATH:-}")"
CLEAN_CMAKE_PREFIX_PATH="$(clean_beegfs_paths "${CMAKE_PREFIX_PATH:-}")"

{
    echo '#!/bin/bash'
    echo
    echo '# Generated automatically by openfoam_build.sh.'
    echo '# /beegfs/Tools must be bound at build and runtime.'
    echo
    printf 'export MPI_HOME=%q\n' "$MPI_HOME"

    if [[ -n "$CLEAN_PATH" ]]; then
        printf 'export PATH=%q:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}\n' "$CLEAN_PATH"
    else
        echo 'export PATH="${MPI_HOME}/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"'
    fi

    if [[ -n "$CLEAN_LD_LIBRARY_PATH" ]]; then
        printf 'export LD_LIBRARY_PATH=%q:${LD_LIBRARY_PATH:-}\n' "$CLEAN_LD_LIBRARY_PATH"
    else
        echo 'export LD_LIBRARY_PATH="${MPI_HOME}/lib:${LD_LIBRARY_PATH:-}"'
    fi

    [[ -n "$CLEAN_LIBRARY_PATH" ]] &&
        printf 'export LIBRARY_PATH=%q:${LIBRARY_PATH:-}\n' "$CLEAN_LIBRARY_PATH"

    [[ -n "$CLEAN_PKG_CONFIG_PATH" ]] &&
        printf 'export PKG_CONFIG_PATH=%q:${PKG_CONFIG_PATH:-}\n' "$CLEAN_PKG_CONFIG_PATH"

    [[ -n "$CLEAN_CMAKE_PREFIX_PATH" ]] &&
        printf 'export CMAKE_PREFIX_PATH=%q:${CMAKE_PREFIX_PATH:-}\n' "$CLEAN_CMAKE_PREFIX_PATH"

    echo
    echo 'unset CPATH'
    echo 'unset C_INCLUDE_PATH'
    echo 'unset CPLUS_INCLUDE_PATH'
} >"$ENV_FILE"

chmod 644 "$ENV_FILE"

test -s "$ENV_FILE" || {
    echo "ERROR: $ENV_FILE is empty."
    exit 15
}

bash -n "$ENV_FILE" || {
    echo "ERROR: $ENV_FILE contains invalid syntax."
    exit 16
}

grep -q 'OpenMPI/4.1.5-GCC-12.3.0' "$ENV_FILE" || {
    echo "ERROR: OpenMPI path is absent from $ENV_FILE."
    exit 17
}

if grep -Eq '^export (CPATH|C_INCLUDE_PATH|CPLUS_INCLUDE_PATH)=' "$ENV_FILE"; then
    echo "ERROR: Compiler include variables entered $ENV_FILE."
    cat "$ENV_FILE"
    exit 18
fi

cat "$ENV_FILE"

rm -f "$IMAGE" "$BUILD_LOG" "$ERROR_LOG"

set +e
apptainer build \
    --force \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    --bind "${BASE_DIR}:${BASE_DIR}" \
    "$IMAGE" \
    "$DEF_FILE"
BUILD_RC=$?
set -e

if [[ "$BUILD_RC" -ne 0 ]]; then
    echo "ERROR: Apptainer build failed with exit code $BUILD_RC"
    [[ -f "$ERROR_LOG" ]] && cat "$ERROR_LOG" || true
    [[ -f "$BUILD_LOG" ]] && tail -n 500 "$BUILD_LOG" || true
    exit "$BUILD_RC"
fi

test -s "$IMAGE" || {
    echo "ERROR: Image was not created or is empty."
    exit 30
}

ls -lh "$IMAGE"

set +e
apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMAGE" \
    /bin/bash -lc '
        set -e
        set -o pipefail

        . /opt/host_mpi_env.sh

        unset CPATH
        unset C_INCLUDE_PATH
        unset CPLUS_INCLUDE_PATH

        export FOAM_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-v2406
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

        set +e
        set +u
        set +o pipefail
        . "$WM_PROJECT_DIR/etc/bashrc"
        set -e
        set -o pipefail

        unset CPATH
        unset C_INCLUDE_PATH
        unset CPLUS_INCLUDE_PATH

        test -n "${WM_OPTIONS:-}" || exit 1
        mpirun --version | sed -n "1p" | grep -q "4.1.5" || exit 2

        for foam_command in blockMesh decomposePar reconstructPar fireFoam
        do
            command -v "$foam_command" >/dev/null 2>&1 || exit 3
            echo "$foam_command: $(command -v "$foam_command")"
        done

        FIREFOAM_BIN="$(command -v fireFoam)"

        if ldd "$FIREFOAM_BIN" | grep -q "not found"; then
            echo "ERROR: fireFoam has unresolved libraries."
            exit 4
        fi

        RANDOM_PROCESSES_LIB="$FOAM_LIBBIN/librandomProcesses.so"
        test -f "$RANDOM_PROCESSES_LIB" || exit 5

        if ldd "$RANDOM_PROCESSES_LIB" | grep -q "not found"; then
            echo "ERROR: librandomProcesses.so has unresolved libraries."
            exit 6
        fi

        echo "FFTW linkage:"
        ldd "$RANDOM_PROCESSES_LIB" | grep -i fftw || exit 7

        PSTREAM_LIBRARY="$FOAM_LIBBIN/${FOAM_MPI:-sys-openmpi}/libPstream.so"

        if [[ ! -f "$PSTREAM_LIBRARY" && -f "$FOAM_LIBBIN/sys-openmpi/libPstream.so" ]]; then
            PSTREAM_LIBRARY="$FOAM_LIBBIN/sys-openmpi/libPstream.so"
        fi

        test -f "$PSTREAM_LIBRARY" || exit 8
        echo "Pstream library: $PSTREAM_LIBRARY"
        ldd "$PSTREAM_LIBRARY"

        if ldd "$PSTREAM_LIBRARY" | grep -q "not found"; then
            echo "ERROR: Pstream has unresolved libraries."
            exit 9
        fi

        MPI_LDD_LINE="$(
            ldd "$PSTREAM_LIBRARY" |
            grep -m1 -E "^[[:space:]]*libmpi[.]so([.][0-9]+)*[[:space:]]*=>"
        )"

        test -n "$MPI_LDD_LINE" || exit 10
        echo "$MPI_LDD_LINE"

        case "$MPI_LDD_LINE" in
            *"/beegfs/Tools/"*"OpenMPI/4.1.5-GCC-12.3.0/"*) ;;
            *) exit 11 ;;
        esac

        ompi_info --param pml ucx --level 1 >/tmp/container_ucx.txt 2>&1 || true
        grep -q "MCA pml: ucx" /tmp/container_ucx.txt || exit 12

        echo "Container verification completed successfully."
    '
VERIFY_RC=$?
set -e

if [[ "$VERIFY_RC" -ne 0 ]]; then
    echo "ERROR: Container verification failed with exit code $VERIFY_RC"
    exit "$VERIFY_RC"
fi

echo "============================================================"
echo "OPENFOAM-v2406 CONTAINER BUILD COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "Image: $IMAGE"
echo "Build log: $BUILD_LOG"
echo "Required bind: --bind /beegfs/Tools:/beegfs/Tools:ro"

exit 0

