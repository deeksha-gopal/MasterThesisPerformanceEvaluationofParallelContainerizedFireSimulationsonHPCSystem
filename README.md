# Master Thesis:- "Performance Evaluation of Parallel Containerized Fire Simulations on HPC System"

The repository contains both the final benchmark scripts used for the performance results reported in the thesis and the preliminary scripts used during benchmark development.

For each benchmark application, the `host` and `container` directories contain the scripts used for the final native-host and Apptainer measurements and the Apptainer definition files and build scripts used to construct the application containers.

The `preliminary_results` directories contain earlier benchmark configurations used during the development of the experimental methodology, including different mesh sizes and standard and explicit MPI execution configurations.

Apptainer `.sif` container images are not included in the repository because they are generated binary images. The corresponding Apptainer definition files required to build the containers are provided instead.
