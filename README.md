# promgeflow-utils

Scripts and utilities for running proMGEflow on the bwHelix HPC.

## Running proMGEflow
Recommended to run from an interactive slurm session:
- `screen` (or tmux) 
- `salloc -n 1 -t 4-00:00:00 --mem=10G --partition=cpu-single`
```{bash}
module load devel/miniforge
module load system/singularity/3.11.3
conda activate promgeflow
bash path/to/install_dir/run_promgeflow.sh {PARAMS}
```

## Notes
At the time of writing, there are issues with the mgexpose (v3.8.0) and
reCOGnise (v0.7.x) containers. As a workaround, this configuration of the
pipeline uses conda envs for both.
