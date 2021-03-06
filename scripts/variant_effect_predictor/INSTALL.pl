#!/usr/bin/env perl

=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2017] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

INSTALL.pl - a script to install required code and data for the VEP

Version 87

by Will McLaren (wm2@ebi.ac.uk)
=cut

use Getopt::Long;
use File::Path qw(mkpath rmtree);
use File::Copy;
use File::Copy::Recursive qw(dircopy);
use File::Basename;
use Archive::Extract;
use Net::FTP;
use Cwd;
use strict;

$| = 1;
our $VERSION = 88;
our $have_LWP;
our $use_curl = 0;
have_LWP();

# CONFIGURE
###########

our ($DEST_DIR, $ENS_CVS_ROOT, $API_VERSION, $ASSEMBLY, $ENS_GIT_ROOT, $BIOPERL_URL, $CACHE_URL, $CACHE_DIR, $PLUGINS, $PLUGIN_URL, $FASTA_URL, $FTP_USER, $help, $UPDATE, $SPECIES, $AUTO, $QUIET, $PREFER_BIN, $CONVERT, $TEST, $NO_HTSLIB, $LIB_DIR, $HTSLIB_DIR, $BIODBHTS_DIR, $REALPATH_DEST_DIR );

GetOptions(
  'DESTDIR|d=s'  => \$DEST_DIR,
  'VERSION|v=i'  => \$API_VERSION,
  'ASSEMBLY|y=s' => \$ASSEMBLY,
  'BIOPERL|b=s'  => \$BIOPERL_URL,
  'CACHEURL|u=s' => \$CACHE_URL,
  'CACHEDIR|c=s' => \$CACHE_DIR,
  'FASTAURL|f=s' => \$FASTA_URL,
  'HELP|h'       => \$help,
  'UPDATE|n'     => \$UPDATE,
  'SPECIES|s=s'  => \$SPECIES,
  'PLUGINS|g=s'  => \$PLUGINS,
  'PLUGINURL=s'  => \$PLUGIN_URL,
  'AUTO|a=s'     => \$AUTO,
  'QUIET|q'      => \$QUIET,
  'PREFER_BIN|p' => \$PREFER_BIN,
  'CONVERT|t'    => \$CONVERT,
  'TEST'         => \$TEST,
  'NO_HTSLIB|l'  => \$NO_HTSLIB,
  'CURL'         => \$use_curl,
) or die("ERROR: Failed to parse arguments");

if(defined($help)) {
  usage();
  exit(0);
}

my $default_dir_used;
my $this_os =  $^O;

# check if $DEST_DIR is default
if(defined($DEST_DIR)) {
  print "Using non-default API installation directory $DEST_DIR.\n";
  print "Please note this just specifies the location for downloaded API files. The variant_effect_predictor.pl script will remain in its current location where ensembl-tools was unzipped.\n";
  print "Have you \n";
  print "1. added $DEST_DIR to your PERL5LIB environment variable?\n";
  print "2. added $DEST_DIR/htslib to your PATH environment variable?\n";
  if( $this_os eq 'darwin' && !$NO_HTSLIB) {
    print "3. added $DEST_DIR/htslib to your DYLD_LIBRARY_PATH environment variable?\n";
  }
  print "(y/n)";

  my $ok = <>;
  if($ok !~ /^y/i) {
    print "Exiting. Please \n";
    print "1. add $DEST_DIR to your PERL5LIB environment variable\n";
    print "2. add $DEST_DIR/htslib to your PATH environment variable\n";
    if( $this_os eq 'darwin' && !$NO_HTSLIB) {
      print "3. add $DEST_DIR/htslib to your DYLD_LIBRARY_PATH environment variable\n";
    }
    exit(0);
  }
  if( ! -d $DEST_DIR ) {
    mkdir $DEST_DIR || die "Could not make destination directory $DEST_DIR"
  }
  $default_dir_used = 0;
}

else {
  $DEST_DIR ||= '.';
  $default_dir_used = 1;
  my $current_dir = cwd();

  if( !$NO_HTSLIB && $this_os eq 'darwin' ) {
    print "Have you \n";
    print "1. added $current_dir/htslib to your DYLD_LIBRARY_PATH environment variable?\n";
    print "(y/n)";
    my $ok = <>;
    if($ok !~ /^y/i) {
      print "Exiting. Please \n";
      print "1. add $current_dir/htslib to your DYLD_LIBRARY_PATH environment variable\n";
      exit(0);
    }
  }
}

$LIB_DIR = $DEST_DIR;

$DEST_DIR       .= '/Bio';
$REALPATH_DEST_DIR  .= Cwd::realpath($DEST_DIR);
$ENS_GIT_ROOT ||= 'https://github.com/Ensembl/';
$BIOPERL_URL  ||= 'https://github.com/bioperl/bioperl-live/archive/release-1-6-924.zip';
$API_VERSION  ||= $VERSION;
$CACHE_URL    ||= "ftp://ftp.ensembl.org/pub/release-$API_VERSION/variation/VEP";
$CACHE_DIR    ||= $ENV{HOME} ? $ENV{HOME}.'/.vep' : 'cache';
$PLUGIN_URL   ||= 'https://raw.githubusercontent.com/Ensembl/VEP_plugins';
$FTP_USER     ||= 'anonymous';
$FASTA_URL    ||= "ftp://ftp.ensembl.org/pub/release-$API_VERSION/fasta/";
$PREFER_BIN     = 0 unless defined($PREFER_BIN);
$HTSLIB_DIR   = $LIB_DIR.'/htslib';
$BIODBHTS_DIR    = $LIB_DIR.'/biodbhts';

my $dirname = dirname(__FILE__) || '.';

#dev


# using PREFER_BIN can save memory when extracting archives
$Archive::Extract::PREFER_BIN = $PREFER_BIN == 0 ? 0 : 1;

$QUIET = 0 unless $UPDATE || $AUTO;

# set up the URLs
my $ensembl_url_tail = '/archive/release/';
my $archive_type = '.zip';

our (@store_species, @indexes, @files, $ftp, $ua);

# update?
if($UPDATE) {
  update();
}

# auto?
elsif($AUTO) {

  # check
  die("ERROR: Failed to parse AUTO string - must contain any of a (API), l (FAIDX/htslib), c (cache), f (FASTA), p (plugins)\n") unless $AUTO =~ /^[alcfp]+$/i;

  # require species
  if($AUTO =~ /[cf]/i) {
    die("ERROR: No species specified\n") unless $SPECIES;
    $SPECIES = [split /\,/, $SPECIES];
  }

  # require plugin list
  if($AUTO =~ /p/i) {
    die("ERROR: No plugins specified\n") unless $PLUGINS;
    $PLUGINS = [split /\,/, $PLUGINS];
  }

  # run subs
  if($AUTO =~ /l/ && $AUTO !~ /a/) {
    my $curdir = getcwd;
    chdir $curdir;
    install_biodbhts();
    chdir $curdir;

    # remove Bio dir if empty
    opendir DIR, $DEST_DIR;
    my @files = grep {!/^\./} readdir DIR;
    closedir DIR;

    if(scalar @files <= 1) {
      rmtree($DEST_DIR.'/'.$files[0]);
      rmtree($DEST_DIR);
    }
  }

  api()   if $AUTO =~ /a/;
  cache() if $AUTO =~ /c/;
  fasta() if $AUTO =~ /f/;
  plugins() if $AUTO =~ /p/;
}

else {
  print "\nHello! This installer is configured to install v$API_VERSION of the Ensembl API for use by the VEP.\nIt will not affect any existing installations of the Ensembl API that you may have.\n\nIt will also download and install cache files from Ensembl's FTP server.\n\n" unless $QUIET;

  # run subs
  api() if check_api();
  cache();
  fasta();
  plugins();
}


# clean up
if(-d "$CACHE_DIR/tmp" && !$TEST) {
  rmtree("$CACHE_DIR/tmp") or die "ERROR: Could not delete directory $CACHE_DIR/tmp\n";
}

print "\nAll done\n" unless $QUIET;


##########################################################################
##########################################################################
##########################################################################


# API
#####
sub api() {
  setup_dirs();
  my $curdir = getcwd;
  bioperl();

  unless($NO_HTSLIB) {
    chdir $curdir;
    install_biodbhts();
  }

  chdir $curdir;
  install_api();
  test();
}


# CHECK EXISTING
################
sub check_api() {
  print "Checking for installed versions of the Ensembl API..." unless $QUIET;

  # test if the user has the API installed
  my $has_api = {
    'ensembl' => 0,
    'ensembl-variation' => 0,
    'ensembl-functgenomics' => 0,
  };

  eval q{
    use Bio::EnsEMBL::Registry;
  };

  my $installed_version;

  unless($@) {
    $has_api->{ensembl} = 1;

    $installed_version = Bio::EnsEMBL::Registry->software_version;
  }

  eval q{
    use Bio::EnsEMBL::Variation::Utils::VEP;
  };

  $has_api->{'ensembl-variation'} = 1 unless $@;

  eval q{
    use Bio::EnsEMBL::Funcgen::RegulatoryFeature;
  };

  $has_api->{'ensembl-functgenomics'} = 1 unless $@;


  print "done\n";

  my $total = 0;
  $total += $_ for values %$has_api;

  my $message;

  if($total == 3) {

    if(defined($installed_version)) {
      if($installed_version == $API_VERSION) {
        $message = "It looks like you already have v$API_VERSION of the API installed.\nYou shouldn't need to install the API";
      }

      elsif($installed_version > $API_VERSION) {
        $message = "It looks like this installer is for an older distribution of the API than you already have";
      }

      else {
        $message = "It looks like you have an older version (v$installed_version) of the API installed.\nThis installer will install a limited set of the API v$API_VERSION for use by the VEP only";
      }
    }

    else {
      $message = "It looks like you have an unidentified version of the API installed.\nThis installer will install a limited set of the API v$API_VERSION for use by the VEP only"
    }
  }

  elsif($total > 0) {
    $message = "It looks like you already have the following API modules installed:\n\n".(join "\n", grep {$has_api->{$_}} keys %$has_api)."\n\nThe VEP requires the ensembl, ensembl-variation and optionally ensembl-functgenomics modules";
  }

  if(defined($message)) {
    print $message unless $QUIET;

    print "\n\nSkip to the next step (n) to install cache files\n\nDo you want to continue installing the API (y/n)? ";
    my $ok = <>;

    if($ok !~ /^y/i) {
      print " - skipping API installation\n" unless $QUIET;
      return 0;
    }
    else {
      return 1;
    }
  }

  else {
    return 1;
  }
}


# SETUP
#######
sub setup_dirs() {

  print "\nSetting up directories\n" unless $QUIET;

  # check if install dir exists
  if(-e $DEST_DIR) {
    my $ok;

    if($AUTO) {
      $ok = 'y';
    }
    else {
      print "Destination directory $DEST_DIR already exists.\nDo you want to overwrite it (if updating VEP this is probably OK) (y/n)? ";

      $ok = <>;
    }

    if($ok !~ /^y/i) {
      print "Exiting\n";
      exit(0);
    }

    else {
      unless($default_dir_used || $AUTO) {
        print "WARNING: You are using a non-default install directory.\nPressing \"y\" again will remove $DEST_DIR and its contents!!!\nAre you really, really sure (y/n)? ";
        $ok = <>;

        if($ok !~ /^y/i) {
          print "Exiting\n";
          exit(0);
        }
      }

      # try to delete the existing dir
      rmtree($DEST_DIR) or die "ERROR: Could not delete directory $DEST_DIR\n";
    }
  }

  mkdir($DEST_DIR) or die "ERROR: Could not make directory $DEST_DIR\n";
  mkdir($DEST_DIR.'/tmp') or die "ERROR: Could not make directory $DEST_DIR/tmp\n";
}


# INSTALL API
#############
sub install_api() {

  print "\nDownloading required Ensembl API files\n" unless $QUIET;

  foreach my $module(qw(ensembl ensembl-variation ensembl-funcgen)) {
    my $url = $ENS_GIT_ROOT.$module.$ensembl_url_tail.$API_VERSION.$archive_type;

    print " - fetching $module\n" unless $QUIET;
    my $target_file = $DEST_DIR.'/tmp/'.$module.$archive_type;

    if(!-e $DEST_DIR.'/tmp/')
    {
        mkdir( $DEST_DIR.'/tmp/' );
    }

    if(!-e $target_file) {
      download_to_file($url, $target_file);
    }

    print " - unpacking $target_file\n" unless $QUIET;
    unpack_arch("$DEST_DIR/tmp/$module$archive_type", "$DEST_DIR/tmp/");

    print " - moving files\n" unless $QUIET;

    if($module eq 'ensembl') {
      move("$DEST_DIR/tmp/$module\-release\-$API_VERSION/modules/Bio/EnsEMBL", "$DEST_DIR/EnsEMBL") or die "ERROR: Could not move directory\n".$!;
    }
    elsif($module eq 'ensembl-variation') {
      move("$DEST_DIR/tmp/$module\-release-$API_VERSION/modules/Bio/EnsEMBL/Variation", "$DEST_DIR/EnsEMBL/Variation") or die "ERROR: Could not move directory\n".$!;

      # move test data
      my $test_target = "$DEST_DIR/../t/testdata/";
      mkpath($test_target) unless -d $test_target;

      opendir TESTDATA, "$DEST_DIR/tmp/$module\-release-$API_VERSION/modules/t/testdata" or die "ERROR: Could not find ensembl-variation/modules/t/testdata directory";

      foreach my $f(grep {!/^\./} readdir TESTDATA) {
        if(-d $test_target.$f) {
          rmtree($test_target.$f) or die "ERROR: Could not remove $test_target$f\n".$!;
        }
        elsif(-e $test_target.$f) {
          unlink($test_target.$f) or die "ERROR: Could not remove $test_target$f\n".$!;
        }

        move("$DEST_DIR/tmp/$module\-release-$API_VERSION/modules/t/testdata/$f", $test_target.$f) or die "ERROR: Could not move $DEST_DIR/tmp/$module\-release-$API_VERSION/modules/t/testdata/$f to $test_target$f".$!;
      }
      closedir TESTDATA;
    }
    elsif($module eq 'ensembl-funcgen') {
      move("$DEST_DIR/tmp/$module\-release-$API_VERSION/modules/Bio/EnsEMBL/Funcgen", "$DEST_DIR/EnsEMBL/Funcgen") or die "ERROR: Could not move directory\n".$!;
    }

    rmtree("$DEST_DIR/tmp/$module\-release-$API_VERSION") or die "ERROR: Failed to remove directory $DEST_DIR/tmp/$module\-release-$API_VERSION\n";
  }
}

# HTSLIB download/make
######################
sub install_htslib() {

  #actually decided to follow Bio::DB::Sam template
  # STEP 0: various dependencies
  my $git = 'which git';
  $git or die <<END;
  'git' command not in path. Please install git and try again.
  (or to skip Bio::DB::HTS/htslib install re-run with --NO_HTSLIB)

  On Debian/Ubuntu systems you can do this with the command:

  apt-get install git
END


  'which cc' or die <<END;
  'cc' command not in path. Please install it and try again.
  (or to skip Bio::DB::HTS/htslib install re-run with --NO_HTSLIB)

  On Debian/Ubuntu systems you can do this with the command:

  apt-get install build-essential
END

  `which make` or die <<END;
  'make' command not in path. Please install it and try again.
  (or to skip Bio::DB::HTS/htslib install re-run with --NO_HTSLIB)

  On Debian/Ubuntu systems you can do this with the command:

  apt-get install build-essential
END

  my $this_os =  $^O;
  if( $this_os ne 'darwin' ) {
    -e '/usr/include/zlib.h' or die <<END;
      zlib.h library header not found in /usr/include. Please install it and try again.
      (or to skip Bio::DB::HTS/htslib install re-run with --NO_HTSLIB)

      On Debian/Ubuntu systems you can do this with the command:

      apt-get install zlib1g-dev
END
 ;
  }

  # STEP 1: Create a clean directory for building
  my $htslib_install_dir = $LIB_DIR;
  my $curdir = getcwd;
  chdir $htslib_install_dir;
  my $actualdir = getcwd;

  # STEP 2: Check out HTSLIB / or make this a download?
  print(" - checking out HTSLib\n");
  system "git clone -b 1.3.2 https://github.com/samtools/htslib.git";
  -d './htslib' or die "git clone seems to have failed. Could not find $htslib_install_dir/htslib directory";
  chdir './htslib';

  # Step 3: Build libhts.a
  print(" - building HTSLIB in $htslib_install_dir/htslib\n");
  print( "In ".getcwd."\n" );
  # patch makefile
  rename 'Makefile','Makefile.orig' or die "Couldn't rename Makefile to Makefile.orig: $!";
  open my $in, '<','Makefile.orig'     or die "Couldn't open Makefile for reading: $!";
  open my $out,'>','Makefile.new' or die "Couldn't open Makefile.new for writing: $!";

  while (<$in>) {
    chomp;
    if (/^CFLAGS/ && !/-fPIC/) {
      s/#.+//;  # get rid of comments
      $_ .= " -fPIC -Wno-unused -Wno-unused-result";
    }
  }
  continue {
    print $out $_,"\n";
  }

  close $in;
  close $out;
  rename 'Makefile.new','Makefile' or die "Couldn't rename Makefile.new to Makefile: $!";
  system "make";
  -e 'libhts.a' or die "Compile didn't complete. No libhts.a library file found";

  chdir $curdir;
  my $retval = Cwd::realpath("$htslib_install_dir/htslib") ;
}


# INSTALL Bio::DB::HTS
######################
sub install_biodbhts() {

  print "Attempting to install Bio::DB::HTS and htslib.\n\n>>> If this fails, try re-running with --NO_HTSLIB\n\n";

  my $htslib_location = install_htslib();
  rmtree( $DEST_DIR.'/tmp' );

  #Now install Bio::DB::HTS proper
  my $biodbhts_github_url = "https://github.com/Ensembl/Bio-HTS";
  my $biodbhts_zip_github_url = "$biodbhts_github_url/archive/master.zip";
  my $biodbhts_zip_download_file = $DEST_DIR.'/tmp/biodbhts.zip';

  mkdir $DEST_DIR unless -d $DEST_DIR;
  mkdir $DEST_DIR.'/tmp';
  download_to_file($biodbhts_zip_github_url, $biodbhts_zip_download_file);
  print " - unpacking $biodbhts_zip_download_file to $DEST_DIR/tmp/\n" unless $QUIET;
  unpack_arch($biodbhts_zip_download_file, "$DEST_DIR/tmp/");

  my $tmp_name = -d "$DEST_DIR/tmp/Bio-HTS-master" ? 'Bio-HTS-master' : 'Bio-DB-HTS-master';

  print "$DEST_DIR/tmp/$tmp_name - moving files to $BIODBHTS_DIR\n" unless $QUIET;
  rmtree($BIODBHTS_DIR);
  move("$DEST_DIR/tmp/$tmp_name", $BIODBHTS_DIR) or die "ERROR: Could not move directory\n".$!;

  print( " - making Bio::DB:HTS\n" );
  # patch makefile
  chdir $BIODBHTS_DIR;
  rename 'Build.PL','Build.PL.orig' or die "Couldn't rename Build to Build.orig: $!";
  open my $in, '<','Build.PL.orig'     or die "Couldn't open Build.PL.orig for reading: $!";
  open my $out,'>','Build.PL.new' or die "Couldn't open Build.PL.new for writing: $!";

  while (<$in>) {
    chomp;
    if (/LIBS/) {
      s/#.+//;  # get rid of comments
      $_ = "LIBS              => ['-L../htslib/ -lhts  -lz'],";
    }

    if (/INC/) {
      s/#.+//;  # get rid of comments
      $_ = "INC               => '-I. -I../htslib', ";
    }
  }
  continue {
    print $out $_,"\n";
  }

  close $in;
  close $out;
  rename 'Build.PL.new','Build.PL' or die "Couldn't rename Build.new to Build: $!";
  system "perl Build.PL --htslib $htslib_location";
  system "./Build";
  chdir ".";

  #move the library
  my $pdir = getcwd;

  #Perl modules to go alongside the API
  dircopy("lib/Bio",$REALPATH_DEST_DIR);

  #The shared object XS library
  if( -e "blib/arch/auto/Bio/DB/HTS/HTS.so" ) {
    copy( "blib/arch/auto/Bio/DB/HTS/Faidx/Faidx.so", "..")
      or die "ERROR: Could not copy shared Faidx.so library:$!\n";
    copy( "blib/arch/auto/Bio/DB/HTS/HTS.so", "..")
      or die "ERROR: Could not copy shared HTS.so library:$!\n";
  }
  elsif( -e "blib/arch/auto/Bio/DB/HTS/HTS.bundle" ) {
    copy( "blib/arch/auto/Bio/DB/HTS/Faidx/Faidx.bundle", "..")
      or die "ERROR: Could not copy shared Faidx.bundle library:$!\n";
    copy( "blib/arch/auto/Bio/DB/HTS/HTS.bundle", "..")
      or die "ERROR: Could not copy shared HTS.bundle library:$!\n";
  }
  else {
    die "ERROR: Shared Bio::DB:HTS library not found\n";
  }

  chdir $pdir;
}


# INSTALL BIOPERL
#################
sub bioperl() {

  # now get BioPerl
  print " - fetching BioPerl\n" unless $QUIET;

  my $bioperl_file = (split /\//, $BIOPERL_URL)[-1];

  my $target_file = $DEST_DIR.'/tmp/'.$bioperl_file;

  download_to_file($BIOPERL_URL, $target_file);

  print " - unpacking $target_file\n" unless $QUIET;
  unpack_arch("$DEST_DIR/tmp/$bioperl_file", "$DEST_DIR/tmp/");

  print " - moving files\n" unless $QUIET;

  my $bioperl_dir;

  if($BIOPERL_URL =~ /github/) {
    $bioperl_file =~ s/\.zip//;
    $bioperl_dir = "bioperl-live-".$bioperl_file;
  }
  else {
    $bioperl_file =~ /(bioperl.+?)\.tar\.gz/i;
    $bioperl_dir = $1;
  }

  opendir BIO, "$DEST_DIR/tmp/$bioperl_dir/Bio/";
  move("$DEST_DIR/tmp/$bioperl_dir/Bio/$_", "$DEST_DIR/$_") for readdir BIO;
  closedir BIO;

  rmtree("$DEST_DIR/tmp") or die "ERROR: Failed to remove directory $DEST_DIR/tmp\n";
}


# TEST
######
sub test() {

  print "\nTesting VEP script\n" unless $QUIET;

  eval q{use Test::Harness};
  if(!$@) {
    $ENV{PERL5LIB} = $ENV{PERL5LIB} ? $ENV{PERL5LIB}.':'.$DEST_DIR : $DEST_DIR;
    opendir TEST, "$dirname\/t";
    my @test_files = map {"$dirname\/t\/".$_} grep {!/_db/ && !/^\./ && /\.t$/} readdir TEST;
    closedir TEST;

    print "Warning: Tests failed, VEP may not run correctly\n" unless runtests(@test_files);
  }
  else {
    my $test_vep = `perl -I $DEST_DIR $dirname/variant_effect_predictor.pl --help 2>&1`;

    $test_vep =~ /ENSEMBL VARIANT EFFECT PREDICTOR/ or die "ERROR: Testing VEP script failed with the following error\n$test_vep\n";
  }

  print " - OK!\n" unless $QUIET;
}


# CACHE FILES
#############
sub cache() {

  my $ok;

  if($AUTO) {
    $ok = $AUTO =~ /c/i ? 'y' : 'n';
  }
  else {
    print "\nThe VEP can either connect to remote or local databases, or use local cache files.\nUsing local cache files is the fastest and most efficient way to run the VEP\n" unless $QUIET;
    print "Cache files will be stored in $CACHE_DIR\n" unless $QUIET;

    print "Do you want to install any cache files (y/n)? ";

    $ok = <>;
  }

  if($ok !~ /^y/i) {
    print "Skipping cache installation\n" unless $QUIET;
    return;
  }

  # check cache dir exists
  if(!(-e $CACHE_DIR)) {
    if(!$AUTO) {
      print "Cache directory $CACHE_DIR does not exists - do you want to create it (y/n)? ";

      my $ok = <>;

      if($ok !~ /^y/i) {
        print "Exiting\n";
        exit(0);
      }
    }

    mkdir($CACHE_DIR) or die "ERROR: Could not create directory $CACHE_DIR\n";
  }

  mkdir($CACHE_DIR.'/tmp') unless -e $CACHE_DIR.'/tmp';

  # get list of species
  print "\Getting list of available cache files\n" unless $QUIET;

  my $num = 1;
  my $species_list;

  if($CACHE_URL =~ /^ftp/i) {
    $CACHE_URL =~ m/(ftp:\/\/)?(.+?)\/(.+)/;
    $ftp = Net::FTP->new($2, Passive => 1) or die "ERROR: Could not connect to FTP host $2\n$@\n";
    $ftp->login($FTP_USER) or die "ERROR: Could not login as $FTP_USER\n$@\n";
    $ftp->binary();

    foreach my $sub(split /\//, $3) {
      $ftp->cwd($sub) or die "ERROR: Could not change directory to $sub\n$@\n";
    }

    push @files, sort grep {$_ =~ /tar.gz/} $ftp->ls;
  }
  else {
    opendir DIR, $CACHE_URL;
    @files = sort grep {$_ =~ /tar.gz/} readdir DIR;
    closedir DIR;
  }

  # if we don't have a species list, we'll have to guess
  if(!scalar(@files)) {
    print "Could not get current species list - using predefined list instead\n";
    print "For more species, see http://www.ensembl.org/info/docs/tools/vep/script/vep_cache.html#pre\n";

    @files = (
      "bos_taurus_vep_".$API_VERSION."_UMD3.1.tar.gz",
      "danio_rerio_vep_".$API_VERSION."_Zv9.tar.gz",
      "homo_sapiens_vep_".$API_VERSION."_GRCh37.tar.gz",
      "homo_sapiens_vep_".$API_VERSION."_GRCh38.tar.gz",
      "mus_musculus_vep_".$API_VERSION."_GRCm38.tar.gz",
      "rattus_norvegicus_vep_".$API_VERSION."_Rnor_5.0.tar.gz",
    );
  }

  foreach my $file(@files) {
    $species_list .= $num++." : ".$file."\n";
  }

  if($AUTO) {
    if($SPECIES->[0] eq 'all') {
      @indexes = (1..(scalar @files));
    }

    else {
      foreach my $sp(@$SPECIES) {
        my @matches;

        for my $i(0..$#files) {
          if($sp =~ /refseq|merged/i) {
            push @matches, $i + 1 if $files[$i] =~ /$sp/i;
          }
          else {
            push @matches, $i + 1 if $files[$i] =~ /$sp/i && $files[$i] !~ /refseq|merged/i;
          }
        }

        # grep assembly if supplied
        @matches = grep {$files[$_ - 1] =~ /\_$ASSEMBLY\./} @matches if $ASSEMBLY;

        if(scalar @matches == 1) {
          push @indexes, @matches;
        }
        elsif(scalar @matches > 1) {
          # xenopus_tropicalis_vep_76_JGI_4.2.tar.gz

          my @assemblies = ();
          foreach my $m(@matches) {
            $files[$m-1] =~ m/\_vep\_$API_VERSION\_(.+?)\.tar\.gz/;
            push @assemblies, $1 if $1;
          }

          die("ERROR: Multiple assemblies found (".join(", ", @assemblies).") for $sp; select one using --ASSEMBLY [name]\n")
        }
      }
    }

    die("ERROR: No matching species found") unless scalar @indexes;

    # uniquify and sort
    @indexes = sort {$a <=> $b} keys %{{map {$_ => 1} @indexes}};
  }
  else {
    print "The following species/files are available; which do you want (can specify multiple separated by spaces or 0 for all): \n$species_list\n? ";
    @indexes = split /\s+/, <>;

    # user wants all species found
    if(scalar @indexes == 1 && $indexes[0] == 0) {
      @indexes = 1..(scalar @files);
    }
  }

  foreach my $file(@indexes) {
    die("ERROR: File number $file not valid\n") unless defined($file) && $file =~ /^[0-9]+$/ && defined($files[$file - 1]);

    my $file_path = $files[$file - 1];

    my $refseq = 0;
    my ($species, $assembly, $file_name);

    if($file_path =~ /\//) {
      ($species, $file_name) = (split /\//, $file_path);
      $file_name =~ m/^(\w+?)\_vep\_\d+\_(.+?)\.tar\.gz/;
      $assembly = $2;
    }
    else {
      $file_name = $file_path;
      $file_name =~ m/^(\w+?)\_vep\_\d+\_(.+?)\.tar\.gz/;
      $species = $1;
      $assembly = $2;
    }

    push @store_species, $species;

    # check if user already has this species and version
    if(-e "$CACHE_DIR/$species/$API_VERSION\_$assembly") {

      my $ok;

      print "\nWARNING: It looks like you already have the cache for $species $assembly (v$API_VERSION) installed.\n" unless $QUIET;

      if($AUTO) {
        print "\nDelete the folder $CACHE_DIR/$species/$API_VERSION\_$assembly and re-run INSTALL.pl if you want to re-install\n";
      }
      else {
        print "If you continue the existing cache will be overwritten.\nAre you sure you want to continue (y/n)? ";

        $ok = <>;
      }

      if($ok !~ /^y/i) {
        print " - skipping $species\n" unless $QUIET;
        next;
      }

      rmtree("$CACHE_DIR/$species/$API_VERSION\_$assembly") or die "ERROR: Could not delete directory $CACHE_DIR/$species/$API_VERSION\_$assembly\n";
    }

    if($species =~ /refseq/i) {
      print "NB: Remember to use --refseq when running the VEP with this cache!\n" unless $QUIET;
    }
    if($species =~ /merged/i) {
      print "NB: Remember to use --merged when running the VEP with this cache!\n" unless $QUIET;
    }

    my $target_file = "$CACHE_DIR/tmp/$file_name";
    if($CACHE_URL =~ /^ftp/) {
      print " - downloading $CACHE_URL/$file_path\n" unless $QUIET;
      if(!$TEST) {
        $ftp->get($file_name, $target_file) or download_to_file("$CACHE_URL/$file_path", $target_file);

        my $checksums = "CHECKSUMS";
        my $checksums_target_file = "$CACHE_DIR/tmp/$checksums";
        $ftp->get($checksums, $checksums_target_file) or download_to_file("$CACHE_URL/$checksums", $checksums_target_file);
        if (-e $checksums_target_file) {
          my $sum_download = `sum $target_file`;
          $sum_download =~ m/([0-9]+)(\s+)([0-9]+)/;
          my $checksum_download = $1;
          $checksum_download =~ s/^0*//;
          my $sum_ftp = `grep $file_name $checksums_target_file`;
          $sum_ftp =~ s/^0*//;
          if ($sum_download && $sum_ftp) {
            die("ERROR: checksum for $target_file doesn't match checksum in CHECKSUMS file on FTP site\n") if ($sum_ftp !~ m/^$checksum_download\s+/);
          }
        }
      }
    }
    else {
      print " - copying $CACHE_URL/$file_path\n" unless $QUIET;
      copy("$CACHE_URL/$file_path", $target_file) unless $TEST;
    }

    print " - unpacking $file_name\n" unless $QUIET;


    unpack_arch($target_file, $CACHE_DIR.'/tmp/') unless $TEST;

    # does species dir exist?
    if(!-e "$CACHE_DIR/$species" && !$TEST) {
      mkdir("$CACHE_DIR/$species") or die "ERROR: Could not create directory $CACHE_DIR/$species\n";
    }

    # move files
    unless($TEST) {
      opendir CACHEDIR, "$CACHE_DIR/tmp/$species/";
      move("$CACHE_DIR/tmp/$species/$_", "$CACHE_DIR/$species/$_") for readdir CACHEDIR;
      closedir CACHEDIR;
    }

    # convert?
    if($CONVERT && !$TEST) {
      print " - converting cache\n" unless $QUIET;
      system("perl $dirname/convert_cache.pl --dir $CACHE_DIR --species $species --version $API_VERSION\_$assembly") == 0 or print STDERR "WARNING: Failed to run convert script\n";
    }
  }
}


# FASTA FILES
#############
sub fasta() {

  ### SPECIAL CASE GRCh37
  if((grep {$files[$_ - 1] =~ /GRCh37/} @indexes) || (defined($ASSEMBLY) && $ASSEMBLY eq 'GRCh37')) {

    # can't install other species at same time as the FASTA URL has to be changed
    if(grep {$files[$_ - 1] !~ /GRCh37/} @indexes) {
      die("ERROR: For technical reasons this installer is unable to install GRCh37 caches alongside others; please install them separately\n");
    }

    # change URL to point to last e! version that had GRCh37 downloads
    elsif($FASTA_URL =~ /ftp/) {
      print "\nWARNING: Changing FTP URL for GRCh37\n";
      $FASTA_URL =~ s/$API_VERSION/75/;
    }
  }

  my $ok;

  if($AUTO) {
    $ok = $AUTO =~ /f/i ? 'y' : 'n';
  }
  else {
    print "\nThe VEP can use FASTA files to retrieve sequence data for HGVS notations and reference sequence checks.\n" unless $QUIET;
    print "FASTA files will be stored in $CACHE_DIR\n" unless $QUIET;
    print "Do you want to install any FASTA files (y/n)? ";

    $ok = <>;
  }

  if($ok !~ /^y/i) {
    print "Skipping FASTA installation - Exiting\n";
    return;
  }

  my @dirs = ();

  if($FASTA_URL =~ /^ftp/i) {
    $FASTA_URL =~ m/(ftp:\/\/)?(.+?)\/(.+)/;
    $ftp = Net::FTP->new($2, Passive => 1) or die "ERROR: Could not connect to FTP host $2\n$@\n";
    $ftp->login($FTP_USER) or die "ERROR: Could not login as $FTP_USER\n$@\n";
    $ftp->binary();

    foreach my $sub(split /\//, $3) {
      $ftp->cwd($sub) or die "ERROR: Could not change directory to $sub\n$@\n";
    }

    push @dirs, sort $ftp->ls;
  }
  else {
    opendir DIR, $FASTA_URL;
    @dirs = grep {-d $FASTA_URL.'/'.$_ && $_ !~ /^\./} readdir DIR;
    closedir DIR;
  }

  my $species_list = '';
  my $num = 1;
  foreach my $dir(@dirs) {
    $species_list .= $num++." : ".$dir."\n";
  }

  my @species;
  if($AUTO) {
    if($SPECIES->[0] eq 'all') {
      @species = scalar @store_species ? @store_species : @dirs;
    }
    else {
      @species = scalar @store_species ? @store_species : @$SPECIES;
    }
  }
  else {
    print "FASTA files for the following species are available; which do you want (can specify multiple separated by spaces, \"0\" to install for species specified for cache download): \n$species_list\n? ";

    my $input = <>;
    my @nums = split /\s+/, $input;

    @species = @store_species if grep {$_ eq '0'} @nums;
    push @species, $dirs[$_ - 1] for grep {$_ > 0} @nums;
  }

  foreach my $species(@species) {

    # remove refseq name
    my $orig_species = $species;
    $species =~ s/_refseq//;
    $species =~ s/_merged//;

    my @files;

    if($ftp) {
      $ftp->cwd($species) or die "ERROR: Could not change directory to $species\n$@\n";
      $ftp->cwd('dna') or die "ERROR: Could not change directory to dna\n$@\n";
      @files = $ftp->ls;
    }
    else {
      if(!opendir DIR, "$FASTA_URL/$species/dna") {
        warn "WARNING: Could not read from directory $FASTA_URL/$species/dna\n$@\n";
        next;
      }
      @files = grep {$_ !~ /^\./} readdir DIR;
      closedir DIR;
    }

    # remove repeat/soft-masked files
    @files = grep {!/_(s|r)m\./} @files;

    my ($file) = grep {/primary_assembly.fa.gz$/} @files;
    ($file) = grep {/toplevel.fa.gz$/} @files if !defined($file);

    unless(defined($file)) {
      warn "WARNING: No download found for $species\n";
      next;
    }

    # work out assembly version from file name
    my $uc_species = ucfirst($species);
    $file =~ m/^$uc_species\.(.+?)(\.)?(\d+)?\.dna/;
    my $assembly = $1;

    # second number could be an Ensembl release number (pre-76) or part of the assembly name
    if(defined($3)) {
      if(!grep {$3 == $_} (69..75)) {
        $assembly .= $2.$3;
      }
    }

    die("ERROR: Unable to parse assembly name from $file\n") unless $assembly;

    my $ex = "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/$file";
    $ex =~ s/\.gz$//;
    if(-e $ex) {
      print "Looks like you already have the FASTA file for $orig_species, skipping\n" unless $QUIET;

      if($ftp) {
        $ftp->cwd('../');
        $ftp->cwd('../');
      }
      next;
    }

    # create path
    mkdir($CACHE_DIR) unless -d $CACHE_DIR || $TEST;
    mkdir("$CACHE_DIR/$orig_species") unless -d "$CACHE_DIR/$orig_species" || $TEST;
    mkdir("$CACHE_DIR/$orig_species/$API_VERSION\_$assembly") unless -d "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly" || $TEST;

    if($ftp) {
      print " - downloading $file\n" unless $QUIET;
      if(!$TEST) {
        $ftp->get($file, "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/$file") or download_to_file("$FASTA_URL/$species/dna/$file", "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/$file");
      }
    }
    else {
      print " - copying $file\n" unless $QUIET;
      copy("$FASTA_URL/$species/dna/$file", "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/$file") unless $TEST;
    }

    if($NO_HTSLIB) {
      print " - extracting data\n" unless $QUIET;
      unpack_arch("$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/$file", "$CACHE_DIR/$orig_species/$API_VERSION\_$assembly/") unless $TEST;

      print " - attempting to index\n" unless $QUIET;
      eval q{
        use Bio::DB::Fasta;
      };
      if($@) {
        print "Indexing failed - VEP will attempt to index the file the first time you use it\n" unless $QUIET;
      }
      else {
        Bio::DB::Fasta->new($ex) unless $TEST;
        print " - indexing OK\n" unless $QUIET;
      }

      print "The FASTA file should be automatically detected by the VEP when using --cache or --offline. If it is not, use \"--fasta $ex\"\n\n" unless $QUIET;
    }

    else {
      print " - converting sequence data to bgzip format\n" unless $QUIET;
      my $curdir = getcwd;
      my $bgzip_convert = "$BIODBHTS_DIR/scripts/convert_gz_2_bgz.sh "."$ex.gz $HTSLIB_DIR/bgzip";
      print " Going to run:\n$bgzip_convert\nThis may take some time and will be removed when files are provided in bgzip format\n";
      my $bgzip_result = `/bin/bash $bgzip_convert` unless $TEST;

      if( $? != 0 ) {
        die "FASTA gzip to bgzip conversion failed: $bgzip_result\n" unless $TEST;
      }
      else {
        print "Converted FASTA gzip file to bgzip successfully\n";
      }

      #Indexing needs Faidx, but this will not be present when the script is started up.
      eval q{
        use Bio::DB::HTS::Faidx;
      };

      if($@) {
        print "Indexing failed - VEP will attempt to index the file the first time you use it\n" unless $QUIET;
      }
      else {
        Bio::DB::HTS::Faidx->new("$ex.gz") unless $TEST;
        print " - indexing OK\n" unless $QUIET;
      }

      print "The FASTA file should be automatically detected by the VEP when using --cache or --offline. If it is not, use \"--fasta $ex.gz\"\n\n" unless $QUIET;
    }

    if($ftp) {
      $ftp->cwd('../');
      $ftp->cwd('../');
    }
  }
}


# UPDATE
########
sub update() {
  eval q{ use JSON; };
  die("ERROR: Updating requires JSON Perl module\n$@") if $@;

  print "Checking for newer version of the VEP\n";

  eval q{
    use HTTP::Tiny;
  };
  die("ERROR: Updating requires HTTP::Tiny Perl module\n$@") if $@;
  my $http = HTTP::Tiny->new();

  my $server = 'http://rest.ensembl.org';
  my $ext = '/info/software?';
  my $response = $http->get($server.$ext, {
    headers => { 'Content-type' => 'application/json' }
  });

  die "ERROR: Failed to fetch software version number!\n" unless $response->{success};

  if(length $response->{content}) {
    my $hash = decode_json($response->{content});
    die("ERROR: Failed to get software version from JSON response\n") unless defined($hash->{release});

    if($hash->{release} > $VERSION) {

      print "Ensembl reports there is a newer version of the VEP ($hash->{release}) available - do you want to download? ";

      my $ok = <>;

      if($ok !~ /^y/i) {
        print "OK, bye!\n";
        exit(0);
      }

      my $url = $ENS_GIT_ROOT.'ensembl-tools'.$ensembl_url_tail.$hash->{release}.$archive_type;

      my $tmpdir = '.'.$$.'_tmp';
      mkdir($tmpdir);

      print "Downloading version $hash->{release}\n";
      download_to_file($url, $tmpdir.'/variant_effect_predictor'.$archive_type);

      print "Unpacking\n";
      unpack_arch($tmpdir.'/variant_effect_predictor'.$archive_type, $tmpdir);
      unlink($tmpdir.'/variant_effect_predictor'.$archive_type);

      opendir NEWDIR, $tmpdir.'/ensembl-tools-release-'.$hash->{release}.'/scripts/variant_effect_predictor';
      my @new_files = grep {!/^\./} readdir NEWDIR;
      closedir NEWDIR;

      foreach my $new_file(@new_files) {
        if(-e $new_file || -d $new_file) {
          print "Backing up $new_file to $new_file\.bak\_$VERSION\n";
          move($new_file, "$new_file\.bak\_$VERSION");
          move($tmpdir.'/ensembl-tools-release-'.$hash->{release}.'/scripts/variant_effect_predictor/'.$new_file, $new_file);
        }
        else {
          print "Copying file $new_file\n";
          move($tmpdir.'/ensembl-tools-release-'.$hash->{release}.'/scripts/variant_effect_predictor/'.$new_file, $new_file);
        }
      }

      rmtree($tmpdir);

      print "\nLooks good! Rerun INSTALL.pl to update your API and/or get the latest cache files\n";
      exit(0);
    }
    else {
      print "Looks like you have the latest version - no need to update!\n\n";
      print "There may still be post-release patches to the API - run INSTALL.pl without --UPDATE/-n to re-install your API\n";
      exit(0);
    }
  }
}


# PLUGINS
#########

sub plugins() {
  my $ok;

  if($AUTO) {
    $ok = $AUTO =~ /p/i ? 'y' : 'n';
  }
  else {
    print "\nThe VEP can use plugins to add functionality and data.\n" unless $QUIET;
    print "Plugins will be installed in $CACHE_DIR\/Plugins\n" unless $QUIET;

    print "Do you want to install any plugins (y/n)? ";

    $ok = <>;
  }

  if($ok !~ /^y/i) {
    print "Skipping plugin installation\n" unless $QUIET;
    return;
  }

  # check plugin installation dir exists
  if(!(-e $CACHE_DIR)) {
    if(!$AUTO) {
      print "Cache directory $CACHE_DIR does not exists - do you want to create it (y/n)? ";

      my $ok = <>;

      if($ok !~ /^y/i) {
        print "Exiting\n";
        exit(0);
      }
    }

    mkdir($CACHE_DIR) or die "ERROR: Could not create directory $CACHE_DIR\n";
  }
  mkdir($CACHE_DIR.'/Plugins') unless -e $CACHE_DIR.'/Plugins';

  my $plugin_url_root = $PLUGIN_URL.'/release/'.$API_VERSION;

  # download and eval plugin config file
  my $plugin_config_file = $CACHE_DIR.'/Plugins/plugin_config.txt';
  download_to_file($plugin_url_root.'/plugin_config.txt', $plugin_config_file);

  die("ERROR: Could not access plugin config file $plugin_config_file\n") unless($plugin_config_file && -e $plugin_config_file);

  open IN, $plugin_config_file;
  my @content = <IN>;
  close IN;

  my $VEP_PLUGIN_CONFIG = eval join('', @content);
  die("ERROR: Could not eval VEP plugin config file: $@\n") if $@;
  my @plugins = @{$VEP_PLUGIN_CONFIG->{plugins}};

  # get sections
  my @sections = grep {defined($_)} map {defined($_->{section}) ? $_->{section} : undef} @plugins;

  # unique sort in same order
  my ($prev, @new);
  for(@sections) {
    if(!defined($prev) || $prev ne $_) {
      push @new, $_;
    }
    $prev = $_;
  }
  @sections = @new;
  push @sections, '';

  # generate list to present to user
  my (%by_number, %by_key);
  my $i = 1;
  my $plugin_list = '';

  # get length of longest label/key
  my $length = length((sort {length($a->{key}) <=> length($b->{key})} @plugins)[-1]->{key});

  foreach my $section(@sections) {
    my $section_name = $section || (scalar @sections > 1 ? 'Other plugins' : 'Plugins');

    my @section_plugins;

    # check that plugins have plugin_url defined
    # otherwise we can't download it
    if($section eq '') {
      @section_plugins = grep {$_->{plugin_url} && !defined($_->{section})} @plugins;
    }
    else {
      @section_plugins = grep {$_->{plugin_url} && defined($_->{section}) && $_->{section} eq $section} @plugins;
    }

    next unless scalar @section_plugins;
    $plugin_list .= "# $section_name\n";

    $_->{plugin_number} = $i++ for @section_plugins;
    $by_number{$_->{plugin_number}} = $_ for @section_plugins;
    $by_key{lc($_->{key})} = $_ for @section_plugins;

    $plugin_list .= sprintf(
      "%4i: %*s - %s\n",
      $_->{plugin_number},
      0 - $length,
      $_->{key},
      $_->{helptip} || ''
    ) for @section_plugins;
  }

  # now establish which we are installing
  my (@indexes, @selected_plugins);

  # either from user input
  if(!$AUTO) {
    print "\nThe following plugins are available; which do you want (can specify multiple separated by spaces or 0 for all): \n$plugin_list\n? ";
    @indexes = split /\s+/, <>;

    # user wants all species found
    if(scalar @indexes == 1 && $indexes[0] == 0) {
      @indexes = 1..(scalar keys %by_number);
    }

    @selected_plugins = map {$by_number{$_}} grep {$by_number{$_}} @indexes;
  }

  # or from list passed on command line
  else {
    if(lc($PLUGINS->[0]) eq 'all' || $PLUGINS->[0] eq '0') {
      @selected_plugins = sort {$a->{key} cmp $b->{key}} values %by_key;
    }
    else {
      @selected_plugins = map {$by_key{lc($_)}} grep {$by_key{lc($_)}} @$PLUGINS;
    }

    my @not_found = grep {!$by_key{lc($_)}} @$PLUGINS;
    if(@not_found) {
      printf(
        "\nWARNING: The following plugins have not been found: %s\nAvailable plugins: %s\n",
        join(",", @not_found),
        join(",", sort map {$_->{key}} values %by_key)
      );
    }

    if(!@selected_plugins) {
      printf("\nERROR: No valid plugins given\n");
      return;
    }
  }

  # store a flag to warn user at end if any plugins require additional setup
  my $requires_install_or_data = 0;

  foreach my $pl(@selected_plugins) {
    printf("\n - installing \"%s\"\n", $pl->{key});

    my $local_file = $CACHE_DIR.'/Plugins/'.$pl->{key}.'.pm';

    # overwrite?
    if(-e $local_file) {
      printf(
        "%s already installed; %s",
        $pl->{key},
        $AUTO ? "overwriting\n" : "do you want to overwrite (probably OK if updating) (y/n)? "
      );

      my $ok = $AUTO ? 'y' : <>;

      if($ok !~ /^y/i) {
        print " - Skipping\n";
        next;
      }
    }

    # download
    download_to_file($pl->{plugin_url}, $local_file);

    # warn if failed
    unless(-e $local_file) {
      print " - WARNING: Failed to download/install ".$pl->{key}."\n";
      next;
    }

    # additional setup required?
    if($pl->{requires_install} || $pl->{requires_data}) {
      print " - This plugin requires installation\n" if $pl->{requires_install};
      print " - This plugin requires data\n" if $pl->{requires_data};
      print " - See $local_file for details\n";

      $requires_install_or_data = 1;
    }

    else {
      printf(
        " - add \"--plugin %s%s\" to your VEP command to use this plugin\n",
        $pl->{key},
        $pl->{params} ? ',[options]' : ''
      );
    }

    print " - OK\n";
  }

  print "\nNB: One or more plugins that you have installed will not work without installation or downloading data; see logs above\n" if $requires_install_or_data;
}

# OTHER SUBS
############

sub download_to_file {
  my ($url, $file) = @_;

  $url =~ s/([a-z])\//$1\:21\// if $url =~ /ftp/ && $url !~ /\:21/;

  # print STDERR "Downloading $url to $file\n";

  if($use_curl) {
    my $output = `curl --location $url > $file`;
  }

  elsif(have_LWP()) {
    my $response = getstore($url, $file);

    unless($response == 200) {

      # try no proxy
      $ua->no_proxy('github.com');

      $response = getstore($url, $file);

      unless($response == 200) {
        #warn "WARNING: Failed to fetch from $url\nError code: $response\n" unless $QUIET;
        print "Trying to fetch using curl\n" unless $QUIET;
        $use_curl = 1;
        download_to_file($url, $file);
      }
    }
  }
  else {
    my $response = HTTP::Tiny->new(no_proxy => 'github.com')->get($url);

    if($response->{success}) {
      open OUT, ">$file" or die "Could not write to file $file\n";
      binmode OUT;
      print OUT $response->{content};
      close OUT;
    }
    else {
      #warn "WARNING: Failed to fetch from $url\nError code: $response->{reason}\nError content:\n$response->{content}\nTrying without no_proxy\n" unless $QUIET;
      $response = HTTP::Tiny->new->get($url);

      if($response->{success}) {
        open OUT, ">$file" or die "Could not write to file $file\n";
        binmode OUT;
        print OUT $response->{content};
        close OUT;
      }
      else {
        #warn "WARNING: Failed to fetch from $url\nError code: $response->{reason}\nError content:\n$response->{content}\n" unless $QUIET;
        print "Trying to fetch using curl\n" unless $QUIET;
        $use_curl = 1;
        download_to_file($url, $file);
      }
    }
  }
}

sub have_LWP {
  return $have_LWP if defined($have_LWP);

  eval q{
    use LWP::Simple qw(getstore get $ua);
  };

  if($@) {
    $have_LWP = 0;
    warn("Using HTTP::Tiny - this may fail when downloading large files; install LWP::Simple to avoid this issue\n");

    eval q{
      use HTTP::Tiny;
    };

    if($@) {
      die("ERROR: No suitable package installed - this installer requires either HTTP::Tiny or LWP::Simple\n");
    }
  }
  else {
    $have_LWP = 1;

    # set up a user agent's proxy (excluding github)
    $ua->env_proxy;

    # enable progress
    eval q{
      $ua->show_progress(1);
    } unless $QUIET;
  }
}

# unpack a tarball
sub unpack_arch {
  my ($arch_file, $dir) = @_;

  my $ar = Archive::Extract->new(archive => $arch_file);
  my $ok = $ar->extract(to => $dir) or die $ar->error;
  unlink($arch_file);
}

sub usage {
    my $usage =<<END;
#---------------#
# VEP INSTALLER #
#---------------#

version $VERSION

By Will McLaren (wm2\@ebi.ac.uk)

http://www.ensembl.org/info/docs/variation/vep/vep_script.html#installer

Usage:
perl INSTALL.pl [arguments]

Options
=======

-h | --help        Display this message and quit

-d | --DESTDIR     Set destination directory for API install (default = './')
-v | --VERSION     Set API version to install (default = $VERSION)
-c | --CACHEDIR    Set destination directory for cache files (default = '$ENV{HOME}/.vep/')

-n | --UPDATE      EXPERIMENTAL! Check for and download new VEP versions

-a | --AUTO        Run installer without user prompts. Use "a" (API + Faidx/htslib),
                   "l" (Faidx/htslib only), "c" (cache), "f" (FASTA), "p" (plugins) to specify
                   parts to install e.g. -a ac for API and cache
-s | --SPECIES     Comma-separated list of species to install when using --AUTO
-y | --ASSEMBLY    Assembly name to use if more than one during --AUTO
-g | --PLUGINS     Comma-separated list of plugins to install when using --AUTO
-q | --QUIET       Don't write any status output when using --AUTO
-p | --PREFER_BIN  Use this if the installer fails with out of memory errors
-l | --NO_HTSLIB   Don't attempt to install Faidx/htslib

-t | --CONVERT     Convert downloaded caches to use tabix for retrieving
                   co-located variants (requires tabix)


-u | --CACHEURL    Override default cache URL; this may be a local directory or
                   a remote (e.g. FTP) address.
-f | --FASTAURL    Override default FASTA URL; this may be a local directory or
                   a remote (e.g. FTP) address. The FASTA URL/directory must have
                   gzipped FASTA files under the following structure:
                   [species]/[dna]/
END

    print $usage;
}
