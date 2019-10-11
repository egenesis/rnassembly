#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/rnassembly
========================================================================================
 nf-core/rnassembly Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/rnassembly
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/rnassembly --bams '*bam' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Options:
      --genome                      Name of iGenomes reference
      --singleEnd                   Specifies that the input is single end reads

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --genome                      Name of iGenomes reference
      --salmon_index                Path to Salmon index
      --fasta                       Path to genome fasta file
      --gtf                         Path to GTF file
      --saveReference               Save the generated reference files to the results directory
      --gencode                     Use fc_group_features_type = 'gene_type' and pass '--gencode' flag to Salmon
      --compressedReference         If provided, all reference files are assumed to be gzipped and will be unzipped before using
    
    Strandedness:
      --forwardStranded             The library is forward stranded
      --reverseStranded             The library is reverse stranded
      --unStranded                  The default behaviour

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the above in a process, define the following:
//   input:
//   file fasta from fasta
//


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */
if(params.readPaths){
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { bam_stringtieFPKM; bam_featurec; bam_salmon }
} else {
    Channel
        .fromFilePairs( params.reads, size: 1 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .into { bam_stringtieFPKM; bam_featurec; bam_salmon }
}

Channel
    .fromPath(params.gtf, checkIfExists: true)
    .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
    .into { gtf_stringtieFPKM }

forwardStranded = params.forwardStranded
reverseStranded = params.reverseStranded
unStranded = params.unStranded

// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-rnassembly-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/rnassembly Workflow Summary'
    section_href: 'https://github.com/nf-core/rnassembly'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

   /*
   * STEP 12 - stringtie FPKM
   */
  process stringtieFPKM {
      label 'mid_memory'
      tag "${name - '.sorted'}"
      publishDir "${params.outdir}/stringtieFPKM", mode: 'copy',
          saveAs: {filename ->
              if (filename.indexOf("transcripts.gtf") > 0) "transcripts/$filename"
              else if (filename.indexOf("cov_refs.gtf") > 0) "cov_refs/$filename"
              else if (filename.indexOf("ballgown") > 0) "ballgown/$filename"
              else "$filename"
          }

      input:
      set val(name), file(bam) from bam_stringtieFPKM
      file gtf from gtf_stringtieFPKM.collect()

      output:
      file "${name}_transcripts.gtf"
      file "${name}_merged_transcripts.gtf" into stringtieGTF4fc, stringtieGTF4salmon 
      file "${name}.gene_abund.txt"
      file "${name}.cov_refs.gtf"

      script:
      def st_direction = ''
      if (forwardStranded && !unStranded){
          st_direction = "--fr"
      } else if (reverseStranded && !unStranded){
          st_direction = "--rf"
      }
      """
      stringtie $bam \\
          $st_direction \\
          -o ${name}_transcripts.gtf \\
          -v \\
          -G $gtf \\
          -A ${name}.gene_abund.txt \\
          -C ${name}.cov_refs.gtf
      stringtie ${name}_transcripts.gtf --merge -G $gtf -o ${name}_merged_transcripts.gtf
      """
  }

  process featureCounts {
      label 'low_memory'
      tag "${name - '.sorted'}"
      publishDir "${params.outdir}/featureCounts", mode: 'copy',
          saveAs: {filename ->
              if (filename.indexOf("biotype_counts") > 0) "biotype_counts/$filename"
              else if (filename.indexOf("_gene.featureCounts.txt.summary") > 0) "gene_count_summaries/$filename"
              else if (filename.indexOf("_gene.featureCounts.txt") > 0) "gene_counts/$filename"
              else "$filename"
          }

      input:
      set val(name), file(bam) from bam_featurec
      file gtf from stringtieGTF4fc.collect()

      output:
      file "${name}_gene.featureCounts.txt" into geneCounts, featureCounts_to_merge
      file "${name}_gene.featureCounts.txt.summary" into featureCounts_logs

      script:
      def featureCounts_direction = 0
      if (forwardStranded && !unStranded) {
          featureCounts_direction = 1
      } else if (reverseStranded && !unStranded){
          featureCounts_direction = 2
      }
      // Try to get real sample name
      sample_name = name - 'Aligned.sortedByCoord.out' - '_subsamp.sorted'
      """
      featureCounts -a $gtf -g gene_id -t exon -o ${name}_gene.featureCounts.txt -p -s $featureCounts_direction $bam
      """
  }

/*
 * STEP 11 - Transcriptome quantification with Salmon
 */
if (params.pseudo_aligner == 'salmon'){
    process makeSalmonIndex {
        label "salmon"
        tag "$fasta"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                           saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file gtf from stringtieGTF4salmon
        file fasta from fasta4salmon

        output:
        file 'salmon_index' into salmon_index

        script:
        def gencode = params.gencode  ? "--gencode" : ""
        """
        gffread -F -w transcripts.fa -g $fasta ${gtf.baseName}
        salmon index --threads $task.cpus -t transcripts.fa -i salmon_index
        """
    }
    
    process salmon {
        label 'salmon'
        tag "$sample"
        publishDir "${params.outdir}/salmon", mode: 'copy'

        input:
        set sample, file(reads) from trimmed_reads_salmon
        file index from salmon_index.collect()
        file gtf from gtf_salmon.collect()

        output:
        file "${sample}/" into salmon_logs
        set val(sample), file("${sample}/") into salmon_tximport

        script:
        def rnastrandness = params.singleEnd ? 'U' : 'IU'
        if (forwardStranded && !unStranded){
            rnastrandness = params.singleEnd ? 'SF' : 'ISF'
        } else if (reverseStranded && !unStranded){
            rnastrandness = params.singleEnd ? 'SR' : 'ISR'
        }
        def endedness = params.singleEnd ? "-r ${reads[0]}" : "-1 ${reads[0]} -2 ${reads[1]}"
        unmapped = params.saveUnaligned ? "--writeUnmappedNames" : ''
        """
        salmon quant --validateMappings \\
                        --seqBias --useVBOpt --gcBias \\
                        --geneMap ${gtf} \\
                        --threads ${task.cpus} \\
                        --libType=${rnastrandness} \\
                        --index ${index} \\
                        $endedness $unmapped\\
                        -o ${sample}
        """
        }

    process salmon_tximport {
      label 'low_memory'

      input:
      set val(name), file ("salmon/*") from salmon_tximport
      file gtf from gtf_salmon_merge.collect()

      output:
      file "${name}_salmon_gene_tpm.csv" into salmon_gene_tpm
      file "${name}_salmon_gene_counts.csv" into salmon_gene_counts
      file "${name}_salmon_transcript_tpm.csv" into salmon_transcript_tpm
      file "${name}_salmon_transcript_counts.csv" into salmon_transcript_counts

      script:
      """
      parse_gtf.py --gtf $gtf --salmon salmon --id ${params.fc_group_features} --extra ${params.fc_extra_attributes} -o tx2gene.csv
      tximport.r NULL salmon ${name}
      """
    }

    process salmon_merge {
      label 'mid_memory'
      publishDir "${params.outdir}/salmon", mode: 'copy'

      input:
      file gene_tpm_files from salmon_gene_tpm.collect()
      file gene_count_files from salmon_gene_counts.collect()
      file transcript_tpm_files from salmon_transcript_tpm.collect()
      file transcript_count_files from salmon_transcript_counts.collect()

      output:
      file "salmon_merged*.csv" into salmon_merged_ch

      script:
      // First field is the gene/transcript ID
      gene_ids = "<(cut -f1 -d, ${gene_tpm_files[0]} | tail -n +2 | cat <(echo '${params.fc_group_features}') - )"
      transcript_ids = "<(cut -f1 -d, ${transcript_tpm_files[0]} | tail -n +2 | cat <(echo 'transcript_id') - )"

      // Second field is counts/TPM
      gene_tpm = gene_tpm_files.collect{f -> "<(cut -d, -f2 ${f})"}.join(" ")
      gene_counts = gene_count_files.collect{f -> "<(cut -d, -f2 ${f})"}.join(" ")
      transcript_tpm = transcript_tpm_files.collect{f -> "<(cut -d, -f2 ${f})"}.join(" ")
      transcript_counts = transcript_count_files.collect{f -> "<(cut -d, -f2 ${f})"}.join(" ")
      """
      paste -d, $gene_ids $gene_tpm > salmon_merged_gene_tpm.csv
      paste -d, $gene_ids $gene_counts > salmon_merged_gene_counts.csv
      paste -d, $transcript_ids $transcript_tpm > salmon_merged_transcript_tpm.csv
      paste -d, $transcript_ids $transcript_counts > salmon_merged_transcript_counts.csv
      """
    }
} else {
    salmon_logs = Channel.empty()
}


/*
 * STEP 2 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('software_versions/*') from software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}



/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/rnassembly] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/rnassembly] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/rnassembly] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/rnassembly] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/rnassembly] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/rnassembly] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/rnassembly]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/rnassembly]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/rnassembly v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
