#!/usr/bin/perl
# Host the MediaRemote helper library inside the Apple-signed system Perl
# (signing identifier com.apple.perl). Same loading technique as
# github.com/ungive/mediaremote-adapter: DynaLoader installs an exported C
# function as an XSUB, which then serves JSON requests on stdin.
use strict;
use warnings;
use DynaLoader;

die "Usage: perl_helper.pl LIBRARY\n" unless @ARGV == 1;
my ($library) = @ARGV;

my $handle = DynaLoader::dl_load_file($library, 0)
    or die 'dl_load_file failed: ' . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, 'npt_main')
    or die 'dl_find_symbol failed: ' . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub('main::npt_main', $symbol);
npt_main();  # Serves until stdin closes, then exits the process.
