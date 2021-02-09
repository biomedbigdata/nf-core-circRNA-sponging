#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/circrnasponging
========================================================================================
 nf-core/circrnasponging Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/circrnasponging
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/circrnasponging --input '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input data (must be surrounded with quotes)
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more
    Options:
      --genome [str]                  Name of iGenomes reference
      --single_end [bool]             Specifies that the input is single-end reads

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference

    Other options:
      --outdir [file]                 The output directory where the results will be saved
    """.stripIndent() 
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

if(params.test_container_mode){
process test_correlation_analysis{
    label 'process_high'

    publishDir "/nfs/home/students/ciora/nf_circRNA_pipeline/human_data/nf-core_output/second_run/results/sponging", mode: params.publish_dir_mode
    
    input:
    file(correlations) from Channel.value(file("/nfs/home/students/ciora/nf_circRNA_pipeline/human_data/nf-core_output/second_run/results/sponging/filtered_circRNA_miRNA_correlation.tsv"))
    file(miRNA_counts_norm) from Channel.value(file("/nfs/home/students/ciora/nf_circRNA_pipeline/human_data/nf-core_output/second_run/results/miRNA/miRNA_counts_all_samples_libSizeEstNorm.tsv"))
    file(circRNA_counts_norm) from Channel.value(file("/nfs/home/students/ciora/nf_circRNA_pipeline/human_data/nf-core_output/second_run/results/circRNA/circRNA_counts_libSizeEstNorm.tsv"))

    output:
    file("sponging_statistics.txt") into ch_sponging_statistics
    file("plots/*.png") into ch_plots

    script:
    """
    mkdir -p "${params.out_dir}/results/sponging/plots/"
    Rscript "${projectDir}"/bin/correlation_analysis.R $params.dataset $miRNA_counts_norm $circRNA_counts_norm $correlations $params.out_dir
    """
}

} else {

/*
 * CREATE A CHANNEL FOR INPUT READ FILES
 */

Channel
        .fromFilePairs(params.totalRNA_reads, size: params.single_end ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.totalRNA_reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
        .set{ch_totalRNA_reads}

/*
* GENERATE STAR INDEX IN CASE IT IS NOT ALREADY PROVIDED
*/
process generate_star_index{
    label 'process_high'
    publishDir "${params.out_dir}/", mode: params.publish_dir_mode

    input:
    file(fasta) from Channel.value(file(params.fasta))
    file(gtf) from Channel.value(file(params.gtf))            
    
    output:
    file("star_index") into generated_star_index
                      
    when: (params.STAR_index == null)

    script:
    """
    echo "star index is running"
    mkdir star_index
      
    STAR \\
    --runMode genomeGenerate \\
    --runThreadN 8 \\
    --sjdbGTFfile $gtf \\
    --genomeDir star_index/ \\
    --genomeFastaFiles $fasta 
    """
}

ch_star_index = params.STAR_index ? Channel.value(file(params.STAR_index)) : generated_star_index
ch_star_index.view()

/*
* PERFORM READ MAPPING OF totalRNA SAMPLES USING STAR
*/
process STAR {
    label 'process_high'
    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/", mode: params.publish_dir_mode
    
    input:
    set val(sampleID), file(reads) from ch_totalRNA_reads
    file star_index from ch_star_index

    output:
    tuple val(sampleID), file("Chimeric.out.junction") into chimeric_junction_files

    script:
    """
    STAR --chimSegmentMin 10 --runThreadN 10 --genomeDir $star_index --readFilesCommand zcat --readFilesIn $reads
    """
}

/*
* PARSE STAR OUTPUT INTO CIRCExplorer2 FORMAT
*/
process circExplorer2_Parse {
    label 'process_medium'

    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/circExplorer2", mode: params.publish_dir_mode
    
    input:
    tuple val(sampleID), file(chimeric_junction) from chimeric_junction_files

    output:
    tuple val(sampleID), file("back_spliced_junction.bed") into backspliced_junction_bed_files

    script:
    """
    CIRCexplorer2 parse -b "back_spliced_junction.bed" -t STAR $chimeric_junction        
    """
}

/*
* PERFORM circRNA QUANTIFICATION USING CIRCExplorer2
*/
process circExplorer2_Annotate {
    label 'process_medium'

    publishDir "${params.out_dir}/samples/${sampleID}/circRNA_detection/circExplorer2", mode: params.publish_dir_mode
    
    input:
    tuple val(sampleID), file(backspliced_junction_bed) from backspliced_junction_bed_files

    output:
    file("${sampleID}_circularRNA_known.txt") into ch_circRNA_known_files

    script:
    """
    CIRCexplorer2 annotate -r $params.gene_pred -g $params.fasta -b $backspliced_junction_bed -o "${sampleID}_circularRNA_known.txt"
    """
}

/*
* MERGE RAW circRNA RESULTS INTO ONE TABLE SUMMARIZING ALL SAMPLES
*/
process summarize_detected_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_file) from ch_circRNA_known_files.collect()

    output:
    file("circRNA_counts_raw.tsv") into ch_circRNA_counts_raw

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_summarize_results.R $params.dataset $params.out_dir
    """
}

/*
* NORMALIZE RAW circRNA COUNT USING LIBRARY SIZE ESTIMATION
*/
process normalize_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_counts_raw) from ch_circRNA_counts_raw

    output:
    file("circRNA_counts_libSizeEstNorm.tsv") into ch_circRNA_counts_norm

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_results_LibrarySizeEstimation.R $circRNA_counts_raw $params.out_dir
    """
}

ch_circRNA_counts_norm.into { ch_circRNA_counts_norm_filter; ch_circRNA_counts_norm_sponging; ch_circRNA_counts_norm_analysis}


/*
* FILTER circRNAs TO REDUCE LOW EXPRESSED ONES
*/
process filter_circRNAs{
    label 'process_medium'

    publishDir "${params.out_dir}/results/circRNA/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_counts_norm) from ch_circRNA_counts_norm_filter

    output:
    file("circRNA_count_filtered.tsv") into ch_circRNA_counts_filtered

    script:
    """
    Rscript "${projectDir}"/bin/circRNA_filtering.R $circRNA_counts_norm $params.out_dir
    """
}

/*
* FOR THE PREVIOUSLY DETECTED circRNAs EXTRACT FASTA SEQUENCES
*/
process extract_circRNA_sequences {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/input/", mode: params.publish_dir_mode
    
    input:
    file(circRNAs_filtered) from ch_circRNA_counts_filtered

    output:
    file("circRNAs.fa") into circRNAs_fasta

    script:
    """
	bash "${projectDir}"/bin/get_circRNA_sequences.sh $params.fasta $circRNAs_filtered "circRNAs.fa"
    """
}

/*
* DETERMINE miRNA BINDING SITES ON THE PREVIOUSLY DETECTED circRNAs USING miranda
*/
process miranda {
    label 'process_long'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(circRNA_fasta) from circRNAs_fasta

    output:
    file("bind_sites_raw.out") into bind_sites_out

    script:
    """
        miranda $params.mature_fasta $circRNA_fasta -out "bind_sites_raw.out" -quiet
    """
}

/*
* PROCESS miranda OUTPUT INTO A TABLE FORMAT
*/
process binding_sites_processing {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(bind_sites_raw) from bind_sites_out

    output:
    file("bind_sites_processed.txt") into bind_sites_processed

    script:
    """
        echo -e "miRNA\tTarget\tScore\tEnergy-Kcal/Mol\tQuery-Al(Start-End)\tSubject-Al(Start-End)\tAl-Len\tSubject-Identity\tQuery-Identity" > "bind_sites_processed.txt"
        grep -A 1 "Scores for this hit:" $bind_sites_raw | sort | grep ">" | cut -c 2- >> "bind_sites_processed.txt"
    """
}

/*
* FILTER BINDING SITES, KEEP TOP 25%
*/
process binding_sites_filtering {
    label 'process_medium'
    publishDir "${params.out_dir}/results/binding_sites/output/", mode: params.publish_dir_mode
    
    input:
    file(bind_sites_proc) from bind_sites_processed
    
    output:
    file("bindsites_25%_filtered.tsv") into ch_bindsites_filtered

    script:
    """
    Rscript "${projectDir}"/bin/binding_sites_analysis.R ${bind_sites_proc}

    """

}


/*
 * GET miRNA RAW COUNTS
 */
if( params.miRNA_raw_counts != null ) {

    /*
     * IF RAW miRNA COUNTS ARE ALREADY SPECIFIED IN A FILE
     */
    ch_miRNA_counts_raw = Channel.fromPath(params.miRNA_raw_counts) 

} else {
   
    /*
     * PERFORM miRNA DETECTION USING miRDeep2 FROM SPECIFIED READ FILES
     */
    Channel
        .fromFilePairs(params.smallRNA_reads, size: 1)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.smallRNA_reads}\nNB: Path needs to be enclosed in quotes!" }
        .set{ch_smallRNA_reads}

/*
* GENERATE STAR INDEX IN CASE IT IS NOT ALREADY PROVIDED
*/
process generate_bowtie_index{
    label 'process_high'
    publishDir "${params.out_dir}/bowtie_index/", mode: params.publish_dir_mode

    input:
    file(fasta) from Channel.value(file(params.fasta))
    
    output:
    file("${fasta.baseName}*") into ch_generated_bowtie_index
                      
    when: (params.bowtie_index == null)

    script:
    """
    echo "bowtie index is in ${fasta.baseName}"
    bowtie-build $fasta ${fasta.baseName}
    """
}

ch_bowtie_index = params.bowtie_index ? Channel.value(file(params.bowtie_index)) : ch_generated_bowtie_index
ch_bowtie_index.view()



    /*
     * PERFORM miRNA READ MAPPING USING miRDeep2
     */
    process miRDeep2_mapping {
        label 'process_high'
        publishDir "${params.out_dir}/samples/${sampleID}/miRNA_detection/", mode: params.publish_dir_mode

        input:
        tuple val(sampleID), file(read_file) from ch_smallRNA_reads
        file(index) from ch_bowtie_index.collect()
        file(fasta) from Channel.value(file(params.fasta))

        output: 
        tuple val(sampleID), file("reads_collapsed.fa"), file("reads_vs_ref.arf") into ch_miRNA_mapping_output

        script:
        """
        mapper.pl $read_file -e -h -i -j -k $params.miRNA_adapter -l 18 -m -p ${fasta.baseName} -s "reads_collapsed.fa" -t "reads_vs_ref.arf" -v
        """
    }

    /*
     * PERFORM miRNA QUANTIFICATION USING miRDeep2
     */
    process miRDeep2_quantification {
        label 'process_high'
        publishDir "${params.out_dir}/samples/${sampleID}/miRNA_detection/", mode: params.publish_dir_mode
 
        input:
        tuple val(sampleID), file(reads_collapsed_fa), file(reads_vs_ref_arf) from ch_miRNA_mapping_output

        output:
        tuple val(sampleID), file("miRNAs_expressed*") into ch_miRNA_expression_files

        script:
        """
        miRDeep2.pl $reads_collapsed_fa $params.fasta $reads_vs_ref_arf $params.mature_fasta $params.mature_other_fasta $params.hairpin_fasta -t $params.species -d -v 
        """
    }

    /*
     * MERGE RAW miRNA RESULTS INTO ONE TABLE SUMMARIZING ALL SAMPLES
     */
    process summarize_detected_miRNAs{
        label 'process_medium'

        publishDir "${params.out_dir}/results/miRNA/", mode: params.publish_dir_mode
    
        input:
        tuple val(sampleID), file(miRNAs_expressed) from ch_miRNA_expression_files.collect()

        output:
        file("miRNA_counts_raw.tsv") into ch_miRNA_counts_raw

        script:
        """
        Rscript "${projectDir}"/bin/miRNA_summarize_results.R $params.dataset $params.out_dir
        """
    }

}

/*
* NORMALIZE RAW miRNA COUNT USING LIBRARY SIZE ESTIMATION
*/
process normalize_miRNAs{
    label 'process_low'

    publishDir "${params.out_dir}/results/miRNA/", mode: params.publish_dir_mode
    
    input:
    file(miRNA_counts_raw) from ch_miRNA_counts_raw

    output:
    file("miRNA_counts_all_samples_libSizeEstNorm.tsv") into ch_miRNA_counts_norm

    script:
    """
    Rscript "${projectDir}"/bin/miRNA_results_LibrarySizeEstimation.R $miRNA_counts_raw $params.out_dir
    """
}

ch_miRNA_counts_norm.into { ch_miRNA_counts_norm_sponging; ch_miRNA_counts_norm_analysis}


/*
* FOR ALL POSSIBLE circRNA-miRNA PAIRS COMPUTE PEARSON CORRELATION
*/
process compute_correlations{
    label 'process_medium'

    publishDir "${params.out_dir}/results/sponging/", mode: params.publish_dir_mode
    
    input:
    file(miRNA_counts_norm) from ch_miRNA_counts_norm_sponging
    file(circRNA_counts_norm) from ch_circRNA_counts_norm_sponging
    file(filtered_bindsites) from ch_bindsites_filtered

    output:
    file("filtered_circRNA_miRNA_correlation.tsv") into ch_correlations

    script:
    """
    Rscript "${projectDir}"/bin/compute_correlations.R $params.dataset $miRNA_counts_norm $circRNA_counts_norm $filtered_bindsites
    """
}

/*
* ANALYZE THE CORRELATION OF ALL PAIRS AND DETERMINE OVERALL DISTRIBUTION
* USING BINDING SITES INFORMATION. COMPUTE STATISTICS AND PLOTS
*/
process correlation_analysis{
    label 'process_high'

    publishDir "${params.out_dir}/results/sponging/", mode: params.publish_dir_mode
    
    input:
    file(correlations) from ch_correlations
    file(miRNA_counts_norm) from ch_miRNA_counts_norm_analysis
    file(circRNA_counts_norm) from ch_circRNA_counts_norm_analysis

    output:
    file("sponging_statistics.txt") into ch_sponging_statistics
    file("plots/*.png") into ch_plots

    script:
    """
    mkdir -p "${params.out_dir}/results/sponging/plots/"
    Rscript "${projectDir}"/bin/correlation_analysis.R $params.dataset $miRNA_counts_norm $circRNA_counts_norm $correlations $params.out_dir
    """
}



}


