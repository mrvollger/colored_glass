import os
import pandas as pd
import pysam
import numpy as np 

SDIR=os.path.realpath(os.path.dirname(srcdir("env.cfg")))
shell.prefix(f"source {SDIR}/envs/env.cfg ; set -eo pipefail; ")

configfile: "dot_aln.yaml"
#
# global options
#
N = config.pop("nbatch", 200)
SM = config.pop("sample", "sample")
W = config.pop("window", 5000)
ALN_T = config.pop("alnthreads", 4)
F = config.pop("mm_f", 10000)
S = config.pop("mm_s", 1000)

#
# required options 
#
FASTA = config["fasta"]
FAI = FASTA+".fai"
if not os.path.exists(FAI):
  shell(f"samtools faidx {FASTA}")


df = pd.read_csv(FAI, names=["chr", "length", "x", "y","z"], sep="\t")
N_WINDOWS = int(sum(np.ceil(df["length"] / W)))
N = min(N, N_WINDOWS)
IDS = list(range(N))

sys.stderr.write('N batches {} \n'.format(N))

localrules: 
  merge_aln,
  identity,
  pair_end_bed,

wildcard_constraints:
  ID="\d+",
  SM=SM,
  W=W,
  F=F

rule all:
  input:
    alns = expand("results/{SM}.{W}.{F}.bam", SM=SM, W=W, F=F),
    sort = expand("results/{SM}.{W}.{F}.sorted.bam", SM=SM, W=W, F=F),
    beds = expand("results/{SM}.{W}.{F}.bed", SM=SM, W=W, F=F),
    fulls = expand("results/{SM}.{W}.{F}.full.tbl", SM=SM, W=W, F=F),
    cool_s = expand("results/{SM}.{W}.{F}.strand.cool", SM=SM, W=W, F=F),
    cool_i = expand("results/{SM}.{W}.{F}.identity.cool", SM=SM, W=W, F=F),
    cool_sm = expand("results/{SM}.{W}.{F}.strand.mcool", SM=SM, W=W, F=F),
    cool_im = expand("results/{SM}.{W}.{F}.identity.mcool", SM=SM, W=W, F=F),


rule make_windows:
  input:
    fai = FAI
  output:
    bed = temp("temp/{SM}.{W}.bed")
  threads:1 
  resources:
    mem = 1
  shell:"""
bedtools makewindows -g {input.fai} -w {W} > {output.bed}
"""

rule split_windows:
  input:
    bed = rules.make_windows.output.bed
  output:
    bed = temp(expand("temp/{{SM}}.{{W}}.{ID}.bed", ID=IDS))
  threads:1 
  resources:
    mem = 1
  run:
    bed = open(input.bed).readlines()
    splits = np.array_split(np.arange(N_WINDOWS), N, axis=0)
    for i, split in enumerate(splits):
      f = open(f"temp/{wildcards.SM}.{wildcards.W}.{i}.bed", "w+")
      for pos in split:
        f.write(bed[pos])
      f.close()


rule window_fa:
  input:
    ref = FASTA,
    bed = rules.make_windows.output.bed
  output:
    fasta = "results/{SM}.{W}.fasta"
  threads:1 
  resources:
    mem = 4
  shell:"""
bedtools getfasta -fi {input.ref} -bed {input.bed} > {output.fasta}
"""

rule aln:
  input:
    ref = FASTA,
    bed = "temp/{SM}.{W}.{ID}.bed",
    split_ref = rules.window_fa.output.fasta,
  output:
    aln = temp("temp/{SM}.{W}.{F}.{ID}.bam")
  threads: ALN_T 
  resources:
    mem = 4
  shell:"""
minimap2 \
    -t {threads} -f {wildcards.F} -s {S} \
    -ax ava-ont --dual=yes --eqx \
    {input.split_ref} \
    <( bedtools getfasta -fi {input.ref} -bed {input.bed} ) \
    | samtools sort -m 4G \
    -o {output.aln}
"""

rule merge_list:
  input:
    aln = expand("temp/{{SM}}.{{W}}.{{F}}.{ID}.bam", ID=IDS),
  output:
    alns = temp("temp/{SM}.{W}.{F}.list")
  threads: 1
  resources:
    mem = 8
  run:
    open(output.alns, "w+").write("\n".join(input.aln)+"\n")


rule merge_aln:
  input:
    alns = rules.merge_list.output.alns,
    aln = expand("temp/{{SM}}.{{W}}.{{F}}.{ID}.bam", ID=IDS),
    split_ref = rules.window_fa.output.fasta,
  output:
    aln = "results/{SM}.{W}.{F}.bam",
  threads: 4
  resources:
    mem = 4
  shell:"""
samtools cat \
      -b {input.alns} \
      -o {output.aln} 
"""

rule sort_aln:
  input:
    aln = rules.merge_aln.output.aln,
  output:
    aln = "results/{SM}.{W}.{F}.sorted.bam",
  threads: 8
  resources:
    mem = 8
  shell:"""
samtools sort -m 4G -@ {threads} \
	-o {output.aln} {input.aln}
"""


rule identity:
  input:
    aln = rules.merge_aln.output.aln,
  output:
    tbl = "results/{SM}.{W}.{F}.tbl"
  threads: 8
  resources:
    mem = 8
  shell:"""
{SDIR}/samIdentity.py --matches {S} --header \
  {input.aln} > {output.tbl}
"""
 

rule pair_end_bed:
  input:
    tbl = rules.identity.output.tbl,
    fai = FAI,
  output:
    bed = "results/{SM}.{W}.{F}.bed",
    full = "results/{SM}.{W}.{F}.full.tbl"
  threads: 1
  resources:
    mem = 64
  shell:"""
{SDIR}/refmt.py \
    --window {wildcards.W} --fai {input.fai} \
    --full {output.full} \
    {input.tbl} {output.bed}
"""
 

rule cooler_strand:
  input:
    bed = rules.pair_end_bed.output.bed,
    fai = FAI,
  output:
    cool = "results/{SM}.{W}.{F}.strand.cool"
  conda: "envs/cooler.yaml"
  threads: 1
  resources:
    mem = 64
  shell:"""
cat {input.bed} | tail -n +2 \
	| sed 's/\t+\t/\t100\t/g' | sed 's/\t-\t/\t50\t/g' \
      | cooler cload pairs \
        -c1 1 -p1 2 -c2 4 -p2 5 \
				--field count=8:agg=mean,dtype=float \
        --chunksize 50000000000 \
        {input.fai}:{wildcards.W} \
        --zero-based \
        - {output.cool}
"""
#| cut -f 8 | head  -n 1000000 | sort | uniq -c 

rule cooler_identity:
  input:
    bed = rules.pair_end_bed.output.bed,
    fai = FAI,
  output:
    cool = "results/{SM}.{W}.{F}.identity.cool"
  conda: "envs/cooler.yaml"
  threads: 1
  resources:
    mem = 64
  shell:"""
cat {input.bed} | tail -n +2 \
      | cooler cload pairs \
        -c1 1 -p1 2 -c2 4 -p2 5 \
				--field count=7:agg=mean,dtype=float \
        --chunksize 50000000000 \
        {input.fai}:{wildcards.W} \
        --zero-based \
        - {output.cool}

"""
 
rule cooler_zoomify_i:
  input:
    i = rules.cooler_identity.output.cool,
  output:
    i = "results/{SM}.{W}.{F}.identity.mcool"
  conda: "envs/cooler.yaml"
  threads: 8
  resources:
    mem = 8
  shell:"""
cooler zoomify --field count:agg=mean,dtype=float {input.i} \
		-n {threads} \
	 -o {output.i}
"""
  
rule cooler_zoomify_s:
  input:
    s = rules.cooler_strand.output.cool,
  output:
    s = "results/{SM}.{W}.{F}.strand.mcool"
  conda: "envs/cooler.yaml"
  threads: 8
  resources:
    mem = 8
  shell:"""
cooler zoomify --field count:agg=mean,dtype=float {input.s} \
		-n {threads} \
	 -o {output.s}
"""
 



