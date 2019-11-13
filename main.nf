#!/usr/bin/env nextflow




params.reads = ''
params.phred = 33
params.results = './results'
params.minhit = 50
params.pairedEnd = true
params.help = false

def helpMessage() {
    log.info"""
     metaphlan-nf: simple metaphlan2 Nextflow pipeline
     Homepage: https://github.com/maxibor/metaphlan-nf
     Author: Maxime Borry <borry@shh.mpg.de>
    =========================================
    Usage:
    The typical command for running the pipeline is as follows:
    nextflow run maxibor/metaphlan-nf --reads '/path/to/paired_end_reads_*.{1,2}.fastq.gz' --metaphlandb '/path/to/minimetaphlan2_v2_8GB_201904_UPDATE.tgz'
    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)

    Settings:
      --phred                       Specifies the fastq quality encoding (33 | 64). Defaults to ${params.phred}
      --pairedEnd                   Specified if reads are paired-end (true | false). Default = ${params.pairedEnd}

    Options:
      --results                     The output directory where the results will be saved. Defaults to ${params.results}
      --help  --h                   Shows this help page
    """.stripIndent()
}

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

Channel
    .fromFilePairs( params.reads, size: params.pairedEnd ? 2 : 1 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\n" }
	.set {reads_to_trim}

process build_metaphlan_db {

  output:
    stdout into mp_db_path
    
  script:
    """
    metaphlan2.py --install
    """
}


process AdapterRemoval {
    tag "$name"

    label 'expresso'

    input:
        set val(name), file(reads) from reads_to_trim

    output:
        set val(name), file('*.trimmed.fastq') into trimmed_reads
        set val(name), file("*.settings") into adapter_removal_results

    script:
        out1 = name+".pair1.trimmed.fastq"
        out2 = name+".pair2.trimmed.fastq"
        se_out = name+".trimmed.fastq"
        settings = name+".settings"
        if (params.pairedEnd){
            """
            AdapterRemoval --basename $name --file1 ${reads[0]} --file2 ${reads[1]} --trimns --trimqualities --minquality 20 --minlength 30 --output1 $out1 --output2 $out2 --threads ${task.cpus} --qualitybase ${params.phred} --settings $settings
            """
        } else {
            """
            AdapterRemoval --basename $name --file1 ${reads[0]} --trimns --trimqualities --minquality 20 --minlength 30 --output1 $se_out --threads ${task.cpus} --qualitybase ${params.phred} --settings $settings
            """
        }
            
}

process get_read_count {
    tag "$name"

    label 'expresso'

    input:
        set val(name), file(ar_settings) from adapter_removal_results
    output:
        set val(name), stdout into nb_reads_ch
    script:
        """
        grep 'Total number of read pairs:' $ar_settings | cut -d : -f 2 | tr -d '\040\011\012\015'
        """
}


process metaphlan {
    tag "$name"

    label 'intenso'

    publishDir "${params.results}/metaphlan/$name", mode: 'copy'

    input:
        set val(name), file(reads) from trimmed_reads
        val(db) from mp_db_path

    output:
        set val(name), file('*.metaphlan.out') into metaphlan_out
        set val(name), file('*_bowtie.sam') into metaphlan_bowtie_out

    script:
        out = name+".metaphlan.out"
        bt_out = name+"_bowtie.sam"
        tmp_dir = baseDir+"/tmp"
        if (params.pairedEnd){
            """
            metaphlan2.py ${reads[0]},${reads[1]} \\
                          -o $out \\
                          --input_type fastq \\
                          --bowtie2out $bt_out  \\
                          --nproc ${task.cpus} \\
            """    
        } else {
            """
            metaphlan2.py $reads \\
                          -o $out \\
                          --input_type fastq \\
                          --bowtie2out $bt_out  \\
                          --nproc ${task.cpus} \\
            """  
        }
        
}

process metaphlan_parse {
    tag "$name"

    label 'ristretto'

    input:
        set val(name), file(metaphlan_r), val(nb_reads) from metaphlan_out.join(nb_reads_ch)

    output:
        set val(name), file('*.metaphlan_parsed.csv') into metaphlan_parsed

    script:
        out = name+".metaphlan_parsed.csv"
        """
        metaphlan_parse.py -n $nb_reads -o $out $metaphlan_r
        """    
}

process metaphlan_merge {

    label 'ristretto'

    publishDir "${params.results}", mode: 'copy'

    input:
        file(csv_count) from metaphlan_parsed.collect()

    output:
        file('metaphlan_taxon_table.csv') into metaphlan_merged

    script:
        out = "metaphlan_taxon_table.csv"
        """
        merge_metaphlan_res.py -o $out
        """    
}