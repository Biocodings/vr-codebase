package VertRes::TrackQC;
use base qw(VertRes::Pipeline);

use strict;
use warnings;
use LSF;
use VertRes::GTypeCheck;
use VRTrack::VRTrack;
use VRTrack::Lane;
use VRTrack::Mapstats;
use VertRes::Parser::fastqcheck;

our @actions =
(
    # Takes care of naming convention, fastq.gz file names should match
    #   the lane name.
    {
        'name'     => 'rename',
        'action'   => \&rename,
        'requires' => \&rename_requires, 
        'provides' => \&rename_provides,
    },

    # Creates a smaller subsample out of the fastq files to speed up
    #   the QC pipeline.
    {
        'name'     => 'subsample',
        'action'   => \&subsample,
        'requires' => \&subsample_requires, 
        'provides' => \&subsample_provides,
    },

    # Runs bwa to create the .sai files and checks for the presence of 
    #   adapter sequences.
    {
        'name'     => 'process_fastqs',
        'action'   => \&process_fastqs,
        'requires' => \&process_fastqs_requires, 
        'provides' => \&process_fastqs_provides,
    },

    # Runs bwa to create the bam file.
    {
        'name'     => 'map_sample',
        'action'   => \&map_sample,
        'requires' => \&map_sample_requires, 
        'provides' => \&map_sample_provides,
    },

    # Runs glf to check the genotype.
    {
        'name'     => 'check_genotype',
        'action'   => \&check_genotype,
        'requires' => \&check_genotype_requires, 
        'provides' => \&check_genotype_provides,
    },

    # Creates some QC graphs and generate some statistics.
    {
        'name'     => 'stats_and_graphs',
        'action'   => \&stats_and_graphs,
        'requires' => \&stats_and_graphs_requires, 
        'provides' => \&stats_and_graphs_provides,
    },

    # Writes the QC status to the tracking database.
    {
        'name'     => 'update_db',
        'action'   => \&update_db,
        'requires' => \&update_db_requires, 
        'provides' => \&update_db_provides,
    },
);

our $options = 
{
    # Executables
    'blat'            => '/software/pubseq/bin/blat',
    'bwa_exec'        => 'bwa-0.5.3',
    'gcdepth_R'       => '/nfs/users/nfs_p/pd3/cvs/maqtools/mapdepth/gcdepth/gcdepth.R',
    'glf'             => '/nfs/users/nfs_p/pd3/cvs/glftools/glfv3/glf',
    'mapviewdepth'    => 'mapviewdepth_sam',
    'samtools'        => 'samtools',

    'adapters'        => '/software/pathogen/projects/protocols/ext/solexa-adapters.fasta',
    'bsub_opts'       => "-q normal -M5000000 -R 'select[type==X86_64 && mem>5000] rusage[mem=5000]'",
    'gc_depth_bin'    => 20000,
    'gtype_confidence'=> 5.0,
    'sample_dir'      => 'qc-sample',
    'sample_size'     => 50e6,
    'stats'           => '_stats',
    'stats_detailed'  => '_detailed-stats.txt',
    'stats_dump'      => '_stats.dump',
};


# --------- OO stuff --------------

=head2 new

        Example    : my $qc = VertRes::TrackDummy->new( 'sample_dir'=>'dir', 'sample_size'=>1e6 );
        Options    : See Pipeline.pm for general options.

                    # Executables
                    blat            .. blat executable
                    bwa_exec        .. bwa executable
                    gcdepth_R       .. gcdepth R script
                    glf             .. glf executable
                    mapviewdepth    .. mapviewdepth executable
                    samtools        .. samtools executable

                    # Options specific to TrackQC
                    adapters        .. the location of .fa with adapter sequences
                    assembly        .. e.g. NCBI36
                    bsub_opts       .. LSF bsub options for jobs
                    bwa_ref         .. the prefix to reference files, as required by bwa
                    fa_ref          .. the reference sequence in fasta format
                    fai_ref         .. the index to fa_ref generated by samtools faidx
                    gc_depth_bin    .. the bin size for the gc-depth graph
                    gtype_confidence.. the minimum expected glf likelihood ratio
                    snps            .. genotype file generated by hapmap2bin from glftools
                    sample_dir      .. where to put subsamples
                    sample_size     .. the size of the subsample
                    stats_ref       .. e.g. /path/to/NCBI36.stats

=cut

sub VertRes::TrackQC::new 
{
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(%$options,'actions'=>\@actions,@args);
    $self->write_logs(1);

    if ( !$$self{bwa_exec} ) { $self->throw("Missing the option bwa_exec.\n"); }
    if ( !$$self{gcdepth_R} ) { $self->throw("Missing the option gcdepth_R.\n"); }
    if ( !$$self{glf} ) { $self->throw("Missing the option glf.\n"); }
    if ( !$$self{mapviewdepth} ) { $self->throw("Missing the option mapviewdepth.\n"); }
    if ( !$$self{samtools} ) { $self->throw("Missing the option samtools.\n"); }
    if ( !$$self{fa_ref} ) { $self->throw("Missing the option fa_ref.\n"); }
    if ( !$$self{fai_ref} ) { $self->throw("Missing the option fai_ref.\n"); }
    if ( !$$self{gc_depth_bin} ) { $self->throw("Missing the option gc_depth_bin.\n"); }
    if ( !$$self{gtype_confidence} ) { $self->throw("Missing the option gtype_confidence.\n"); }
    if ( !$$self{sample_dir} ) { $self->throw("Missing the option sample_dir.\n"); }
    if ( !$$self{sample_size} ) { $self->throw("Missing the option sample_size.\n"); }

    return $self;
}


=head2 clean

        Description : If mrProper option is set, the entire QC directory will be deleted.
        Returntype  : None

=cut

sub clean
{
    my ($self) = @_;

    $self->SUPER::clean();

    if ( !$$self{'lane_path'} ) { $self->throw("Missing parameter: the lane to be cleaned.\n"); }
    if ( !$$self{'sample_dir'} ) { $self->throw("Missing parameter: the sample_dir to be cleaned.\n"); }

    if ( !$$self{'mrProper'} ) { return; }
    my $qc_dir = qq[$$self{'lane_path'}/$$self{'sample_dir'}];
    if ( ! -d $qc_dir ) { return; }

    $self->debug("rm -rf $qc_dir\n");
    Utils::CMD(qq[rm -rf $qc_dir]);
    return;
}


=head2 lane_info

        Arg[1]      : field name: one of genotype,gtype_confidence
        Description : Temporary replacement of HierarchyUtilities::lane_info. Most of the data are now passed
                        to pipeline from a config file, including gender specific data. What's left are minor
                        things - basename of the lane and expected genotype name and confidence. Time will show
                        where to put this.
        Returntype  : field value

=cut

sub lane_info
{
    my ($self,$field) = @_;

    my $sample = $$self{sample};

    # By default, the genotype is named as sample. The exceptions should be listed
    #   in the known_gtypes hash.
    my $gtype = $sample;
    if ( exists($$self{known_gtypes}) &&  exists($$self{known_gtypes}{$sample}) )
    {
        $gtype = $$self{known_gtypes}{$sample};
    }
    if ( $field eq 'genotype' ) { return $gtype; }

    if ( $field eq 'gtype_confidence' )
    {
        if ( exists($$self{gtype_confidence}) && ref($$self{gtype_confidence}) eq 'HASH' )
        {
            if ( exists($$self{gtype_confidence}{$gtype}) ) { return $$self{gtype_confidence}{$gtype}; }
        }
        elsif ( exists($$self{gtype_confidence}) )
        {
            return $$self{gtype_confidence};
        }

        # If we are here, either there is no gtype_confidence field or it is a hash and does not
        #   contain the key $gtype. In such a case, return unrealisticly high value.
        return 1000;
    }

    $self->throw("Unknown field [$field] to lane_info\n");
}


#---------- rename ---------------------

# Requires nothing
sub rename_requires
{
    my ($self) = @_;
    my @requires = ();
    return \@requires;
}

# It may provide also _2.fastq.gz, but we assume that if
#   there is _1.fastq.gz but _2 is missing, it is OK.
#
sub rename_provides
{
    my ($self) = @_;
    my @provides = ("$$self{lane}_1.fastq.gz");
    return \@provides;
}

# The naming convention is to name fastq files according
#   to the lane, e.g. 
#       project/sample/tech/libr/lane/lane_1.fastq.gz
#       project/sample/tech/libr/lane/lane_2.fastq.gz
#
sub rename
{
    my ($self,$lane_path,$lock_file) = @_;

    my $name = $$self{lane};

    my $fastq_files = existing_fastq_files("$lane_path/$name");

    # They are named correctly.
    if ( scalar @$fastq_files  ) { return $$self{'Yes'}; }

    my @files = glob("$lane_path/*.fastq.gz");
    if ( scalar @files > 2 ) { Utils::error("FIXME: so far can handle up to 2 fastq files: $lane_path.\n") }

    my $i = 0;
    for my $file (sort cmp_last_number @files)
    {
        $i++;
        if ( ! -e "$lane_path/${name}_$i.fastq.gz" )
        {
            Utils::relative_symlink($file,"$lane_path/${name}_$i.fastq.gz");
        }
        if ( -e "$file.fastqcheck" && ! -e "$lane_path/${name}_$i.fastq.gz.fastqcheck" )
        {
            Utils::relative_symlink("$file.fastqcheck","$lane_path/${name}_$i.fastq.gz.fastqcheck");
        }
    }
    return $$self{'Yes'};
}

sub cmp_last_number($$)
{
    my ($a,$b) = @_;
    if ( !($a=~/(\d+)\D*$/) ) { return 0 } # leave unsorted if there is no number in the name
    my $x = $1;
    if ( !($b=~/(\d+)\D*$/) ) { return 0 }
    my $y = $1;
    return $x<=>$y;
}

# How many fastq files there are of the name ${prefix}_[123].fastq.gz?
sub existing_fastq_files
{
    my ($prefix) = @_;

    my @files = ();
    my $i = 1;
    while ( -e "${prefix}_$i.fastq.gz" )
    {
        push @files, "${prefix}_$i.fastq.gz";
        $i++;
    }
    return \@files;
}


#---------- subsample ---------------------

# At least one fastq file is required. We assume that either all fastq files
#   are in place, or there is none.
#
sub subsample_requires
{
    my ($self) = @_;

    my @requires = ("$$self{lane}_1.fastq.gz");
    return \@requires;
}

# We must sample all fastq files but we do not know how many there are.
sub subsample_provides
{
    my ($self,$lane_path) = @_;

    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};

    my $fastq_files = existing_fastq_files("$lane_path/$name");
    my $nfiles = scalar @$fastq_files;
    if ( !$nfiles ) { $self->throw("No fastq.gz files in $lane_path??\n") }

    my @provides = ();
    for (my $i=1; $i<=$nfiles; $i++)
    {
        push @provides, "$sample_dir/${name}_$i.fastq.gz";
    }
    return \@provides;
}

sub subsample
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = $$self{'sample_dir'};
    my $name       = $$self{'lane'};

    Utils::create_dir("$lane_path/$sample_dir/");

    # Dynamic script to be run by LSF.
    open(my $fh, '>', "$lane_path/$sample_dir/_qc-sample.pl") or $self->throw("$lane_path/$sample_dir/_qc-sample.pl: $!");

    my $fastq_files = existing_fastq_files("$lane_path/$name");
    my $nfiles = scalar @$fastq_files;
    if ( !$nfiles ) { $self->throw("No fastq files in $lane_path??") }

    # The files will be created in reverse order, so that that _1.fastq.gz is created 
    #   last - the next action checks only for the first one. If there is only one file,
    #   the variable $seq_list is not used. If there are multiple, $seq_list is passed
    #   only to subsequent calls of FastQ::sample.
    #
    print $fh "use FastQ;\n";
    print $fh '$seq_list = ' unless $nfiles==1;
    for (my $i=$nfiles; $i>0; $i--)
    {
        my $print_seq_list = ($i==$nfiles) ? '' : ', $seq_list';
        print $fh "FastQ::sample(q{../${name}_$i.fastq.gz},q{${name}_$i.fastq.gz}, $$self{'sample_size'}$print_seq_list);\n";
    }
    close $fh;

    LSF::run($lock_file,"$lane_path/$sample_dir","_${name}_sample", $self, qq{perl -w _qc-sample.pl});

    return $$self{'No'};
}



#----------- process_fastqs ---------------------

# If one sample is in place (_1.fastq.gz), we assume all are in place.
sub process_fastqs_requires
{
    my ($self) = @_;

    my $sample_dir = $$self{'sample_dir'};
    my @requires = ("$sample_dir/$$self{lane}_1.fastq.gz");
    return \@requires;
}

sub process_fastqs_provides
{
    my ($self,$lane_path) = @_;

    my @provides = ();
    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};

    my $fastq_files = existing_fastq_files("$lane_path/$sample_dir/$name");
    my $nfiles = scalar @$fastq_files;

    # This should not happen, only when the import is broken.
    if ( !$nfiles ) { return 0; }
    
    for (my $i=1; $i<=$nfiles; $i++)
    {
        push @provides, "$sample_dir/${name}_$i.sai";
        push @provides, "$sample_dir/${name}_$i.nadapters";
    }
    return \@provides;
}

sub process_fastqs
{
    my ($self,$lane_path,$lock_file) = @_;

    if ( !$$self{bwa_ref} ) { $self->throw("Missing the option bwa_ref.\n"); }

    my $name      = $$self{lane};
    my $work_dir  = "$lane_path/$$self{sample_dir}";
    my $prefix    = exists($$self{'prefix'}) ? $$self{'prefix'} : '_';

    my $bwa       = $$self{'bwa_exec'};
    my $bwa_ref   = $$self{'bwa_ref'};
    my $fai_ref   = $$self{'fai_ref'};
    my $samtools  = $$self{'samtools'};

    # How many files do we have?
    my $fastq_files = existing_fastq_files("$work_dir/$name");
    my $nfiles = scalar @$fastq_files;
    if ( $nfiles<1 || $nfiles>2 ) { Utils::error("FIXME: we can handle 1 or 2 fastq files in $work_dir, not $nfiles.\n") }

    # Run bwa aln for each fastq file to create .sai files.
    for (my $i=1; $i<=$nfiles; $i++)
    {
        if ( -e qq[$work_dir/${name}_$i.sai] ) { next; }

        open(my $fh,'>', "$work_dir/${prefix}aln_fastq_$i.pl") or Utils::error("$work_dir/${prefix}aln_fastq_$i.pl: $!");
        print $fh
qq[
use strict;
use warnings;
use Utils;

Utils::CMD("$bwa aln -q 20 -l 32 $bwa_ref ${name}_$i.fastq.gz > ${name}_$i.saix");
if ( ! -s "${name}_$i.saix" ) { Utils::error("The command ended with an error:\n\t$bwa aln -q 20 -l 32 $bwa_ref ${name}_$i.fastq.gz > ${name}_$i.saix\n") }
rename("${name}_$i.saix","${name}_$i.sai") or Utils::CMD("rename ${name}_$i.saix ${name}_$i.sai: \$!");

];
        close($fh);
        LSF::run($lock_file,$work_dir,"_${name}_$i",$self,qq[perl -w ${prefix}aln_fastq_$i.pl]);
    }

    # Run blat for each fastq file to find out how many adapter sequences are in there.
    Utils::CMD(qq[cat $$self{adapters} | sed 's/>/>ADAPTER|/' > $work_dir/adapters.fa]);

    for (my $i=1; $i<=$nfiles; $i++)
    {
        if ( -e qq[$work_dir/${name}_$i.nadapters] ) { next; }

        open(my $fh,'>', "$work_dir/${prefix}blat_fastq_$i.pl") or Utils::error("$work_dir/${prefix}blat_fastq_$i.pl: $!");
        print $fh
qq[
use strict;
use warnings;
use Utils;

Utils::CMD(q[zcat ${name}_$i.fastq.gz | awk '{print ">"substr(\$1,2,length(\$1)); getline; print; getline; getline}' > ${name}_$i.fa ]);
Utils::CMD(q[$$self{blat} adapters.fa ${name}_$i.fa ${name}_$i.blat -out=blast8]);
Utils::CMD(q[cat ${name}_$i.blat | awk '{if (\$2 ~ /^ADAPTER/) print}' | sort -u | wc -l > ${name}_$i.nadapters]);
unlink("${name}_$i.fa", "${name}_$i.blat");
];
        close($fh);
        LSF::run($lock_file,$work_dir,"_${name}_a$i",$self,qq[perl -w ${prefix}blat_fastq_$i.pl]);
    }

    return $$self{'No'};
}



#----------- map_sample ---------------------


sub map_sample_requires
{
    my ($self,$lane_path) = @_;

    my @requires = ();
    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};

    my $fastq_files = existing_fastq_files("$lane_path/$sample_dir/$name");
    my $nfiles = scalar @$fastq_files;
    if ( !$nfiles ) 
    {
        @requires = ("$sample_dir/${name}_1.sai");
        return \@requires;
    }
    
    for (my $i=1; $i<=$nfiles; $i++)
    {
        push @requires, "$sample_dir/${name}_$i.sai";
    }
    return \@requires;
}

sub map_sample_provides
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @provides = ("$sample_dir/$$self{lane}.bam");
    return \@provides;
}

sub map_sample
{
    my ($self,$lane_path,$lock_file) = @_;

    if ( !$$self{bwa_ref} ) { $self->throw("Missing the option bwa_ref.\n"); }

    my $sample_dir = $$self{'sample_dir'};
    my $name       = $$self{lane};
    my $work_dir   = "$lane_path/$$self{sample_dir}";

    my $bwa        = $$self{'bwa_exec'};
    my $bwa_ref    = $$self{'bwa_ref'};
    my $fai_ref    = $$self{'fai_ref'};
    my $samtools   = $$self{'samtools'};


    # How many files do we have?
    my $fastq_files = existing_fastq_files("$work_dir/$name");
    my $nfiles = scalar @$fastq_files;
    if ( $nfiles<1 || $nfiles>2 ) { Utils::error("FIXME: we can handle 1 or 2 fastq files in $work_dir, not $nfiles.\n") }


    my $bwa_cmd  = '';
    if ( $nfiles == 1 )
    {
        $bwa_cmd = "$bwa samse $bwa_ref ${name}_1.sai ${name}_1.fastq.gz";
    }
    else
    {
        $bwa_cmd = "$bwa sampe $bwa_ref ${name}_1.sai ${name}_2.sai ${name}_1.fastq.gz ${name}_2.fastq.gz";
    }

    # Dynamic script to be run by LSF. We must check that the bwa exists alright
    #   - samtools do not return proper status and create .bam file even if there was
    #   nothing read from the input.
    #
    open(my $fh,'>', "$work_dir/_map.pl") or Utils::error("$work_dir/_map.pl: $!");
    print $fh 
qq{
use Utils;

Utils::CMD("$bwa_cmd > ${name}.sam");
if ( ! -s "${name}.sam" ) { Utils::error("The command ended with an error:\n\t$bwa_cmd > ${name}.sam\n") }

Utils::CMD("$samtools import $fai_ref ${name}.sam ${name}.ubam");
Utils::CMD("$samtools sort ${name}.ubam ${name}x");     # Test - will this help from NFS problems?
Utils::CMD("rm -f ${name}.sam ${name}.ubam");
rename("${name}x.bam", "$name.bam") or Utils::CMD("rename ${name}x.bam $name.bam: \$!");
};
    close($fh);

    LSF::run($lock_file,$work_dir,"_${name}_sampe",$self, q{perl -w _map.pl});
    return $$self{'No'};
}




#----------- check_genotype ---------------------

sub check_genotype_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @requires = ("$sample_dir/$$self{lane}.bam");
    return \@requires;
}

sub check_genotype_provides
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @provides = ("$sample_dir/$$self{lane}.gtype");
    return \@provides;
}

sub check_genotype
{
    my ($self,$lane_path,$lock_file) = @_;

    if ( !$$self{snps} ) { $self->throw("Missing the option snps.\n"); }

    my $name = $$self{lane};

    my $options = {};
    $$options{'bam'}           = "$lane_path/$$self{'sample_dir'}/$name.bam";
    $$options{'bsub_opts'}     = $$self{'bsub_opts'};
    $$options{'fa_ref'}        = $$self{'fa_ref'};
    $$options{'glf'}           = $$self{'glf'};
    $$options{'snps'}          = $$self{'snps'};
    $$options{'samtools'}      = $$self{'samtools'};
    $$options{'genotype'}      = $self->lane_info('genotype');
    $$options{'min_glf_ratio'} = $self->lane_info('gtype_confidence');
    $$options{'prefix'}        = $$self{'prefix'};
    $$options{'lock_file'}     = $lock_file;

    my $gtc = VertRes::GTypeCheck->new(%$options);
    $gtc->check_genotype();

    return $$self{'No'};
}


#----------- stats_and_graphs ---------------------

sub stats_and_graphs_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @requires = ("$sample_dir/$$self{lane}.bam");
    return \@requires;
}

sub stats_and_graphs_provides
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @provides = ("$sample_dir/chrom-distrib.png","$sample_dir/gc-content.png","$sample_dir/insert-size.png","$sample_dir/gc-depth.png");
    return \@provides;
}

sub stats_and_graphs
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = $$self{'sample_dir'};
    my $lane  = $$self{lane};
    my $stats_ref = exists($$self{stats_ref}) ? $$self{stats_ref} : '';

    # Dynamic script to be run by LSF.
    open(my $fh, '>', "$lane_path/$sample_dir/_graphs.pl") or Utils::error("$lane_path/$sample_dir/_graphs.pl: $!");
    print $fh 
qq[
use VertRes::TrackQC;

my \%params = 
(
    'gc_depth_bin' => q[$$self{'gc_depth_bin'}],
    'mapviewdepth' => q[$$self{'mapviewdepth'}],
    'samtools'     => q[$$self{'samtools'}],
    'gcdepth_R'    => q[$$self{'gcdepth_R'}],
    'lane_path'    => q[$lane_path],
    'lane'         => q[$$self{lane}],
    'sample_dir'   => q[$$self{'sample_dir'}],
    'fa_ref'       => q[$$self{fa_ref}],
    'fai_ref'      => q[$$self{fai_ref}],
    'stats_ref'    => q[$stats_ref],
);

my \$qc = VertRes::TrackQC->new(\%params);
\$qc->run_graphs(\$params{lane_path});
];
    close $fh;

    LSF::run($lock_file,"$lane_path/$sample_dir","_${lane}_graphs", $self, qq{perl -w _graphs.pl});
    return $$self{'No'};
}


sub run_graphs
{
    my ($self,$lane_path) = @_;

    use Graphs;
    use SamTools;
    use Utils;
    use FastQ;

    # Set the variables
    my $sample_dir   = $$self{'sample_dir'};
    my $name         = $$self{lane};
    my $outdir       = "$lane_path/$sample_dir/";
    my $bam_file     = "$outdir/$name.bam";

    my $samtools     = $$self{'samtools'};
    my $mapview      = $$self{'mapviewdepth'};
    my $refseq       = $$self{'fa_ref'};
    my $fai_ref      = $$self{'fai_ref'};
    my $gc_depth_bin = $$self{'gc_depth_bin'};
    my $bindepth     = "$outdir/gc-depth.bindepth";
    my $gcdepth_R    = $$self{'gcdepth_R'};

    my $stats_file  = "$outdir/$$self{stats}";
    my $other_stats = "$outdir/$$self{stats_detailed}";
    my $dump_file   = "$outdir/$$self{stats_dump}";


    # Create the multiline fastqcheck files
    my @fastq_quals = ();
    my $fastq_files = existing_fastq_files("$lane_path/$name");
    for (my $i=1; $i<=scalar @$fastq_files; $i++)
    {
        my $fastqcheck = "$lane_path/${name}_$i.fastq.gz.fastqcheck";
        if ( !-e $fastqcheck ) { next }

        my $data = FastQ::parse_fastqcheck($fastqcheck);
        $$data{'outfile'}    = "$outdir/fastqcheck_$i.png";
        $$data{'title'}      = "FastQ Check $i";
        $$data{'desc_xvals'} = 'Sequencing Quality';
        $$data{'desc_yvals'} = '1000 x Frequency / nBases';

        # Draw the 'Total' line as the last one and somewhat thicker
        my $total = shift(@{$$data{'data'}});
        $$total{'lines'} = ',lwd=3';
        push @{$$data{'data'}}, $total;

        Graphs::plot_stats($data);

        my $pars = VertRes::Parser::fastqcheck->new(file => $fastqcheck);
        my ($bases,$quals) = $pars->avg_base_quals();
        push @fastq_quals, { xvals=>$bases, yvals=>$quals };
    }

    if ( scalar @fastq_quals )
    {
        Graphs::plot_stats({
                outfile     => qq[$outdir/fastqcheck.png],
                title       => 'fastqcheck base qualities',
                desc_yvals  => 'Quality',
                desc_xvals  => 'Base',
                data        => \@fastq_quals,
                r_plot      => "ylim=c(0,50)",
                });
    }

    # The GC-depth graphs
    if ( ! -e "$outdir/gc-depth.png" || Utils::file_newer($bam_file,$bindepth) )
    {
        Utils::CMD("$samtools view $bam_file | $mapview $refseq -b=$gc_depth_bin > $bindepth");
        Graphs::create_gc_depth_graph($bindepth,$gcdepth_R,qq[$outdir/gc-depth.png]);
    }


    # Get stats from the BAM file
    my $all_stats = SamTools::collect_detailed_bam_stats($bam_file,$fai_ref);
    my $stats = $$all_stats{'total'};
    # report_stats($stats,$lane_path,$stats_file); shouldn't be needed anymore
    report_detailed_stats($stats,$lane_path,$other_stats);
    dump_detailed_stats($stats,$dump_file);


    # Insert size graph
    my ($x,$y);
    if ( exists($$stats{insert_size}) )
    {
        $x = $$stats{'insert_size'}{'max'}{'x'};
        $y = $$stats{'insert_size'}{'max'}{'y'};
        my $insert_size  = $$stats{insert_size}{average}<500 ? 500 : $$stats{insert_size}{average};
        Graphs::plot_stats({
                'outfile'    => qq[$outdir/insert-size.png],
                'title'      => 'Insert Size',
                'desc_yvals' => 'Frequency',
                'desc_xvals' => 'Insert Size',
                'data'       => [ $$stats{'insert_size'} ],
                'r_cmd'      => qq[text($x,$y,'$x',pos=4,col='darkgreen')\n],
                'r_plot'     => "xlim=c(0," . ($insert_size*2.5) . ")",
                });
    }

    # GC content graph
    $x = $$stats{'gc_content_forward'}{'max'}{'x'};
    $y = $$stats{'gc_content_forward'}{'max'}{'y'};
    my $normalize = 0; 
    my @gc_data   = ();
    if ( $$self{stats_ref} ) 
    {
        # Plot also the GC content of the reference sequence
        my ($gc_freqs,@xvals,@yvals);
        eval `cat $$self{stats_ref}`;
        if ( $@ ) { $self->throw($@); }

        for my $bin (sort {$a<=>$b} keys %$gc_freqs)
        {
            push @xvals,$bin;
            push @yvals,$$gc_freqs{$bin};
        }
        push @gc_data, { xvals=>\@xvals, yvals=>\@yvals, lines=>',lty=4' };
        $normalize = 1;
    }
    if ( $$stats{'gc_content_forward'} ) { push @gc_data, $$stats{'gc_content_forward'}; } # Should be always present
    if ( $$stats{'gc_content_reverse'} ) { push @gc_data, $$stats{'gc_content_reverse'}; } # May be not present (single end sequencing)
    Graphs::plot_stats({
            'outfile'    => qq[$outdir/gc-content.png],
            'title'      => 'GC Content (both mapped and unmapped)',
            'desc_yvals' => 'Frequency',
            'desc_xvals' => 'GC Content [%]',
            'data'       => \@gc_data,
            'r_cmd'      => "text($x,$y,'$x',pos=4,col='darkgreen')\n",
            'normalize'  => $normalize,
            });

    # Chromosome distribution graph
    Graphs::plot_stats({
            'barplot'    => 1,
            'outfile'    => qq[$outdir/chrom-distrib.png],
            'title'      => 'Chromosome Coverage',
            'desc_yvals' => 'Frequency/Length',
            'desc_xvals' => 'Chromosome',
            'data'       => [ $$stats{'reads_chrm_distrib'}, ],
            });
}


sub report_stats
{
    my ($stats,$lane_path,$outfile) = @_;

    # This shouldn't be needed anymore.
    return;

    my $info = HierarchyUtilities::lane_info($lane_path);

    my $avg_read_length = $$stats{'bases_total'}/$$stats{'reads_total'};

    open(my $fh,'>',$outfile) or Utils::error("$outfile: $!");
    print  $fh "MAPPED,,$$info{project},$$info{sample},$$info{technology},$$info{library},$$info{lane},";
    printf $fh ",0,$$info{lane}_1.fastq.gz,%.1f,$$info{lane}_2.fastq.gz,%.1f,", $avg_read_length,$avg_read_length;
    print  $fh "$$stats{reads_total},$$stats{bases_total},$$stats{reads_mapped},$$stats{bases_mapped_cigar},$$stats{reads_paired},";
    print  $fh "$$stats{rmdup_reads_total},0,$$stats{error_rate}\n";
    close $fh;
}



sub report_detailed_stats
{
    my ($stats,$lane_path,$outfile) = @_;

    open(my $fh,'>',$outfile) or Utils::error("$outfile: $!");

    printf $fh "reads total .. %d\n", $$stats{'reads_total'};
    printf $fh "     mapped .. %d (%.1f%%)\n", $$stats{'reads_mapped'}, 100*($$stats{'reads_mapped'}/$$stats{'reads_total'});
    printf $fh "     paired .. %d (%.1f%%)\n", $$stats{'reads_paired'}, 100*($$stats{'reads_paired'}/$$stats{'reads_total'});
    printf $fh "bases total .. %d\n", $$stats{'bases_total'};
    printf $fh "    mapped (read)  .. %d (%.1f%%)\n", $$stats{'bases_mapped_read'}, 100*($$stats{'bases_mapped_read'}/$$stats{'bases_total'});
    printf $fh "    mapped (cigar) .. %d (%.1f%%)\n", $$stats{'bases_mapped_cigar'}, 100*($$stats{'bases_mapped_cigar'}/$$stats{'bases_total'});
    printf $fh "duplication .. %f\n", $$stats{'duplication'};
    printf $fh "error rate  .. %f\n", $$stats{error_rate};
    printf $fh "\n";
    printf $fh "insert size        \n";
    if ( exists($$stats{insert_size}) )
    {
        printf $fh "    average .. %.1f\n", $$stats{insert_size}{average};
        printf $fh "    std dev .. %.1f\n", $$stats{insert_size}{std_dev};
    }
    else
    {
        printf $fh "    N/A\n";
    }
    printf $fh "\n";
    printf $fh "chrm distrib dev .. %f\n", $$stats{'reads_chrm_distrib'}{'scaled_dev'};

    close $fh;
}


sub dump_detailed_stats
{
    my ($stats,$outfile) = @_;

    use Data::Dumper;
    open(my $fh,'>',$outfile) or Utils::error("$outfile: $!");
    print $fh Dumper($stats);
    close $fh;
}


#----------- update_db ---------------------

sub update_db_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};
    my @requires = ("$sample_dir/chrom-distrib.png","$sample_dir/gc-content.png","$sample_dir/insert-size.png",
        "$sample_dir/gc-depth.png","$sample_dir/${name}.gtype","$sample_dir/$$self{stats_dump}");
    return \@requires;
}

# This subroutine will check existence of the key 'db'. If present, it is assumed
#   that QC should write the stats and status into the VRTrack database. In this
#   case, 0 is returned, meaning that the task must be run. The task will change the
#   QC status from 'no_qc' to something else, therefore we will not be called again.
#
#   If the key 'db' is absent, the empty list is returned and the database will not
#   be written.
#
sub update_db_provides
{
    my ($self) = @_;

    if ( exists($$self{db}) ) { return 0; }

    my @provides = ();
    return \@provides;
}

sub update_db
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = "$lane_path/$$self{sample_dir}";
    if ( !$$self{db} ) { $self->throw("Expected the db key.\n"); }
    if ( !$$self{assembly} ) { $self->throw("Missing the option assembly.\n"); }
    if ( !$$self{mapper} ) { $self->throw("Missing the option mapper.\n"); }
    if ( !$$self{mapper_version} ) { $self->throw("Missing the option mapper_version.\n"); }

    # First check if the 'no_qc' status is still present. Another running pipeline
    #   could have queued the job a long time ago and the stats might have been
    #   already written.
    my $vrtrack   = VRTrack::VRTrack->new($$self{db}) or $self->throw("Could not connect to the database: ",join(',',%{$$self{db}}),"\n");
    my $name      = $$self{lane};
    my $vrlane    = VRTrack::Lane->new_by_name($vrtrack->{_dbh},$name) or $self->throw("No such lane in the DB: [$name]\n");
    my $qc_status = $vrlane->qc_status();

    # Make sure we don't overwrite info of lanes which were already QC-ed.
    if ( $qc_status ne 'no_qc' && $qc_status ne 'pending' && !$$self{ignore_qc_status} ) { return $$self{Yes}; }

    # Get the stats dump
    my $stats = do "$sample_dir/$$self{stats_dump}";
    if ( !$stats ) { $self->throw("Could not read $sample_dir/$$self{stats_dump}\n"); }

    my $rmdup_reads_mapped = $$stats{rmdup_reads_total} - $$stats{reads_total} + $$stats{reads_mapped};
    my $read_length = $$stats{bases_total} / $$stats{reads_total};

    my $gtype = VertRes::GTypeCheck::get_status("$sample_dir/${name}.gtype");

    my %images = ();
    if ( -e "$sample_dir/chrom-distrib.png" ) { $images{'chrom-distrib.png'} = 'Chromosome Coverage'; }
    if ( -e "$sample_dir/gc-content.png" ) { $images{'gc-content.png'} = 'GC Content'; }
    if ( -e "$sample_dir/insert-size.png" ) { $images{'insert-size.png'} = 'Insert Size'; }
    if ( -e "$sample_dir/gc-depth.png" ) { $images{'gc-depth.png'} = 'GC Depth'; }
    if ( -e "$sample_dir/fastqcheck_1.png" ) { $images{'fastqcheck_1.png'} = 'FastQ Check 1'; }
    if ( -e "$sample_dir/fastqcheck_2.png" ) { $images{'fastqcheck_2.png'} = 'FastQ Check 2'; }

    my $nadapters = 0;
    if ( -e "$sample_dir/${name}_1.nadapters" ) { $nadapters += do "$sample_dir/${name}_1.nadapters"; }
    if ( -e "$sample_dir/${name}_2.nadapters" ) { $nadapters += do "$sample_dir/${name}_1.nadapters"; }

    # Now call the database API and fill the mapstats object with values
    my $mapping = $vrlane->add_mapping();
    $mapping->raw_reads($$stats{reads_total});
    $mapping->raw_bases($$stats{bases_total});
    $mapping->reads_mapped($$stats{reads_mapped});
    $mapping->reads_paired($$stats{reads_paired});
    $mapping->bases_mapped($$stats{bases_mapped_cigar});
    $mapping->error_rate($$stats{error_rate});
    $mapping->rmdup_reads_mapped($rmdup_reads_mapped);
    $mapping->rmdup_bases_mapped($rmdup_reads_mapped * $read_length);
    $mapping->adapter_reads($nadapters);

    $mapping->mean_insert($$stats{insert_size}{average});
    $mapping->sd_insert($$stats{insert_size}{std_dev});

    $mapping->genotype_expected($$gtype{expected});
    $mapping->genotype_found($$gtype{found});
    $mapping->genotype_ratio($$gtype{ratio});
    $vrlane->genotype_status($$gtype{status});

    my $assembly = $mapping->assembly($$self{assembly});
    if (!$assembly) { $assembly = $mapping->add_assembly($$self{assembly}); }

    my $mapper = $mapping->mapper($$self{mapper},$$self{mapper_version});
    if (!$mapper) { $mapper = $mapping->add_mapper($$self{mapper},$$self{mapper_version}); }

    # Do the images
    while (my ($imgname,$caption) = each %images)
    {
        my $img = $mapping->add_image_by_filename("$sample_dir/$imgname");
        $img->caption($caption);
        $img->update;
    }

    # Write the QC status. Never overwrite a QC status set by human, only NULL or no_qc.
    $mapping->update;
    $qc_status = $vrlane->qc_status();
    if ( !$qc_status || $qc_status eq 'no_qc' ) { $vrlane->qc_status('pending'); }
    $vrlane->update;

    return $$self{'Yes'};
}


#---------- Debugging and error reporting -----------------

sub warn
{
    my ($self,@msg) = @_;
    my $msg = join('',@msg);
    if ($self->verbose > 0) 
    {
        print STDERR $msg;
    }
    $self->log($msg);
}

sub debug
{
    my ($self,@msg) = @_;
    if ($self->verbose > 1) 
    {
        my $msg = join('',@msg);
        print STDERR $msg;
        $self->log($msg);
    }
}

sub throw
{
    my ($self,@msg) = @_;
    Utils::error(@msg);
}

sub log
{
    my ($self,@msg) = @_;

    my $msg_str = join('',@msg);
    my $status  = open(my $fh,'>>',$self->log_file);
    if ( !$status ) 
    {
        print STDERR $msg_str;
    }
    else 
    { 
        print $fh $msg_str; 
    }
    if ( $fh ) { close($fh); }
}


1;

