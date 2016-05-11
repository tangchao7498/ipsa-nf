// parameters
params.deltaSS = 10
params.dir = 'A07'
params.entropy = 1.5
params.group = 'labExpId'
params.idr = 0.1
params.margin = 5
params.merge = "all"
params.mincount = 10
params.smpid = 'labExpId'
params.status = 0
params.readLength = 75
params.microexons = false

//print usage
if (params.help) {
  log.info ''
  log.info 'I P S A ~ Integrative Pipeline for Splicing Analyses'
  log.info '----------------------------------------------------'
  log.info 'Run IPSA on a set of data.'
  log.info ''
  log.info 'Usage: '
  log.info '    ipsa.nf [options]'
  log.info ''
  log.info 'Options:'
  log.info '--in INDEX_FILE           the index file'
  log.info '--genome GENOME_FILE      the genome file (FASTA)'
  log.info '--annot ANNOTATION_FILE   the annotation file (gtf)'
  log.info '--deltaSS DELTA           distance threshold for splice sites, default=10'
  log.info '--dir DIRECTORY           the output directory, obligatory'
  log.info '--entropy ENTROPY         entropy lower threshold, default=1.5'
  log.info '--group GROUP             the grouping field for IDR, default=labExpId'
  log.info '--idr IDR                 IDR upper threshold, default=0.1'
  log.info '--margin MARGIN           margin for aggregate, default=5'
  log.info '--merge MERGE             the name of the output to merge in case if blocks are missing, default=all'
  log.info '--mincount MIN_COUNT      min number of counts for the denominator, default=10'
  log.info '--param PARAMS            parameters passed to sjcount'
  log.info '--repository REPOSITORY   the repository subdirectory for bam files'
  log.info '--smpid SAMPLE_ID_FIELD   sample id field, default=labExpId'
  log.info '--status STATUS           annotation status lower threshold, default=0'
  exit 1
}

log.info ""
log.info "I P S A ~ Integrative Pipeline for Splicing Analyses"
log.info ""
log.info "General parameters"
log.info "------------------"
log.info "Index file                         : ${params.in}"
log.info "Genome                             : ${params.genome}"
log.info "Annotation                         : ${params.annot}"
log.info "Splice sites distance threshold    : ${params.deltaSS}"
log.info "Output dir                         : ${params.dir}"
log.info "Entropy lowewr threshold           : ${params.entropy}"
log.info "Grouping field                     : ${params.group}"
log.info "IDR upper threshold                : ${params.idr}"
log.info "Margin for aggregate               : ${params.margin}"
log.info "Merge output name                  : ${params.merge}"
log.info "Minimum counts for denominator     : ${params.mincount}"
log.info "Sjcount parameters                 : ${params.param}"
log.info "BAM files repository               : ${params.repository}"
log.info "Sample id field                    : ${params.smpid}"
log.info "Annotation status lower threshold  : ${params.status}"
log.info "Include microexons                 : ${params.microexons}"
log.info ""

if (params.genome =~ /.fa$/) {
  process genomeIndex {
    input:
    file genome from Channel.fromPath(params.genome)

    output:
    set file("${prefix}.dbx"), file("${prefix}.idx") into genomeIdx
    
    script:
    prefix = genome.name.replace(/.fa/, '')
    """
    transf -dir ./${genome} -dbx ${prefix}.dbx -idx ${prefix}.idx
    """
  }
} else {
  genomeIdx = Channel.create()
  genomeIdx << [file("${params.genome}.dbx"), file("${params.genome}.idx")]
}

if (params.annot =~ /.g[tf]f$/) {
  process txElements {
    input:
    file annotation from Channel.fromPath(params.annot)

    output:
    file "${prefix}.gfx" into txIdxAnnotate, txIdxZeta, txIdxZetaMex

    script:
    prefix = annotation.name.replace(/.gtf/,'')
    """
    transcript_elements.pl - < ${annotation} | sort -k1,1 -k4,5n > ${prefix}.gfx
    """
  }
} else {
  txIdx = Channel.fromPath("${params.annot}")
  (txIdxAnnotate, txIdxZeta, txIdxZetaMex) = txIdx.into(3)
}

process sjcount {
  input:
  file bam from Channel.fromPath(params.bams)

  output:
  set val(1), file("${prefix}.A01.ssj.tsv") into A01
  set val(0), file("${prefix}.A01.ssc.tsv") into A01
  set val(2), file("${prefix}.A01.ssj.tsv") into A01mex

  script:
  prefix = bam.name.replace(/.bam/,'')
  """
  sjcount -bam ${bam} -ssc ${prefix}.A01.ssc.tsv -ssj ${prefix}.A01.ssj.tsv -nbins ${params.readLength} ${params.param} -quiet
  """
}

process aggregate {
  input:
  set splits, file(tsv) from A01

  output:
  file "${prefix}.tsv" into A02

  script:
  prefix = tsv.name.replace(/.tsv/,'').replace(/A01/,'A02')
  """
  awk '\$2==${splits}' ${tsv} | agg.pl -readLength ${params.readLength} -margin ${params.margin} -logfile ${prefix}.log > ${prefix}.tsv 
  """
}

process aggregateMex {
  input:
  set splits, file(tsv) from A01mex

  when:
  params.microexons

  output:
  file "${prefix}.tsv" into D01

  script:
  prefix = tsv.name.replace(/.tsv/,'').replace(/A01.ssj/,'D01')
  """
  awk '\$2==${splits}' ${tsv} | agg.pl -logfile ${prefix}.log > ${prefix}.tsv 
  """
}

ssjA02 = Channel.create()
sscA02 = Channel.create()

A02.choice( ssjA02, sscA02 ) { f ->
    f.name =~ /ssj/ ? 0 : 1
}

process annotate {
  input:
  set file(genomeDBX), file(genomeIDX) from genomeIdx.first()
  file annotation from txIdxAnnotate.first()
  file ssj from ssjA02

  output:
  file "${prefix}.tsv" into A03

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A02/,'A03')
  """
  annotate.pl  -annot ${annotation} -dbx ${genomeDBX} -idx ${genomeIDX} -deltaSS ${params.deltaSS} -in ${ssj} > ${prefix}.tsv
  """
}

process chooseStrand {
  input:
  file ssj from A03

  output:
  file "${prefix}.tsv" into ssjA04, ssj4constrain, ssj4constrainMult

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A03/,'A04')
  """
  choose_strand.pl - < ${ssj}  -logfile ${prefix}.log > ${prefix}.tsv
  """
}

constrain = ssj4constrain.mix(sscA02).groupBy { f ->
   f.baseName.replaceAll(/\.A0[24]\.ss[cj]/,'')
}.map { m ->
     m.values().collect { it.sort { it.baseName } }
}
.flatMap()

if ( params.microexons ) {
  constrainMult = ssj4constrainMult.mix(D01).groupBy { f ->
     f.baseName.replaceAll(/\.(A04\.ssj|D01)/,'')
  }.map { m ->
      m.values().collect { it.sort { it.baseName } }
  }
  .flatMap()
} else {
  constrainMult = Channel.empty()
}

process constrainSSC {
  input:
  set file(ssc), file(ssj) from constrain

  output:
  file "${prefix}.tsv" into sscA04

  script:
  prefix = ssc.name.replace(/.tsv/,'').replace(/A02/,'A04')
  """
  constrain_ssc.pl -ssj ${ssj} < ${ssc} > ${prefix}.tsv  
  """
}

process constrainMex {
  input:
  set file(ssj), file(ssjMex) from constrainMult

  output:
  file "${prefix}.tsv" into D02

  script:
  prefix = ssjMex.name.replace(/.tsv/,'').replace(/D01/,'D02')
  """
  constrain_mult.pl -ssj ${ssj} < ${ssjMex} > ${prefix}.tsv
  """
}

process extractMex {
  input:
  file ssjMex from D02

  output:
  file "${prefix}.tsv" into D03

  script:
  prefix = ssjMex.name.replace(/.tsv/,'').replace(/D02/,'D03')
  """
  extract_mex.pl < ${ssjMex} > ${prefix}.tsv
  """
}

A04 = ssjA04.mix(sscA04)

process idr {
  input:
  file tsv from A04

  output:
  file "${prefix}.tsv" into A05

  script:
  prefix = tsv.name.replace(/.tsv/,'').replace(/A04/,'A05')
  """
  idr4sj.pl ${tsv} > ${prefix}.tsv
  """
}

process idrMex {
  input:
  file tsv from D03

  output:
  file "${prefix}.tsv" into D06

  script:
  prefix = tsv.name.replace(/.tsv/,'').replace(/D03/,'D06')
  """
  idr4sj.pl ${tsv} > ${prefix}.tsv
  """
}

ssjA05 = Channel.create()
sscA05 = Channel.create()

A05.choice( ssjA05,sscA05 ) { f ->
    f.name =~ /ssj/ ? 0 : 1
}

process ssjA06 {
  input:
  file ssj from ssjA05

  output:
  file "${prefix}.tsv" into ssjA06, ssj4gffA06, ssj4allA06

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A05/,'A06')
  """
  awk '\$4>=1.5 && \$5>=0 && \$7<0.1'  ${ssj}  > ${prefix}.tsv
  """
}

process sscA06 {
  input:
  file ssc from sscA05

  output:
  file "${prefix}.tsv" into sscA06, ssc4allA06

  script:
  prefix = ssc.name.replace(/.tsv/,'').replace(/A05/,'A06')
  """
  awk '\$4>=1.5 && \$7<0.1'  ${ssc}  > ${prefix}.tsv
  """
}

if ( ! params.microexons ) {
  D06 = Channel.empty()
}

allA06 = ssj4allA06.mix(ssc4allA06).mix(D06).groupBy { f ->
   f.baseName.replaceAll(/\.(A06\.ss[cj]|D06)/,'')
}.map { m ->
    m.values().collect { it.sort { it.baseName } }
}
.flatMap()

process zeta {
  
  publishDir params.dir

  input:
  file annotation from txIdxZeta.first()
  set file(ssc), file(ssj) from allA06

  output:
  file "${prefix}.gff" into A07

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A06.ssj/,'A07')
  """
  zeta.pl  -annot ${annotation} -ssc ${ssc} -ssj ${ssj} -mincount ${params.mincount} > ${prefix}.gff 
  """
}

process zetaMex {
  
  publishDir params.dir

  input:
  file annotation from txIdxZetaMex.first()
  set file(ssc), file(ssj), file(exons) from allMex

  output:
  file "${prefix}.gff" into A07

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A06.ssj/,'A07')
  """
  zeta.pl  -annot ${annotation} -ssc ${ssc} -ssj ${ssj} -exons ${exons} -mincount ${params.mincount} > ${prefix}.gff 
  """
}


process ssjTsv2bed {
  input:
  file ssj from ssjA06

  output:
  file "${prefix}.bed" into E06

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A06/,'E06')
  """
  tsv2bed.pl  < ${ssj} -extra 2,3,4,5,6,7 > ${prefix}.bed
  """
}

process sscTsv2bed {
  input:
  file ssc from sscA06

  output:
  file "${prefix}.bed" into E06

  script:
  prefix = ssc.name.replace(/.tsv/,'').replace(/A06/,'E06')
  """
  tsv2bed.pl  < ${ssc} -extra 2 -ssc > ${prefix}.bed
  """
}

process tsv2gff {
  input:
  file ssj from ssj4gffA06

  output:
  file "${prefix}.gff" into E06

  script:
  prefix = ssj.name.replace(/.tsv/,'').replace(/A06/,'E06')
  """
  tsv2gff.pl  < ${ssj} -o count 2 -o stagg 3 -o entr 4 -o annot 5 -o nucl 6 -o IDR 7 > ${prefix}.gff
  """
}

workflow.onComplete {
    log.info """
    Pipeline execution summary
    ---------------------------
    Completed at: ${workflow.complete}
    Duration    : ${workflow.duration}
    Success     : ${workflow.success}
    workDir     : ${workflow.workDir}
    exit status : ${workflow.exitStatus}
    Error report: ${workflow.errorReport ?: '-'}
    """
}
