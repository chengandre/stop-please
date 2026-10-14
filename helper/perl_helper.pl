#!/usr/bin/perl
# Host the MediaRemote helper library inside the Apple-signed system Perl
# (signing identifier com.apple.perl). Same loading technique as
# github.com/ungive/mediaremote-adapter: DynaLoader installs an exported C
# function as an XSUB; parameters travel in environment variables.
use strict;
use warnings;
use DynaLoader;

my ($library, $mode, @arguments) = @ARGV;
my $usage = "Usage: perl_helper.pl LIBRARY serve | list | send|override-send <play|pause|next> <pid>\n";
die $usage unless defined $library && defined $mode;
if (($mode eq 'serve' || $mode eq 'list') && !@arguments) {
    $ENV{NPT_MODE} = $mode;
} elsif (($mode eq 'send' || $mode eq 'override-send') && @arguments == 2 && $arguments[1] =~ /^\d+$/) {
    @ENV{qw(NPT_MODE NPT_ACTION NPT_PID)} = ($mode, @arguments);
} else {
    die $usage;
}

my $handle = DynaLoader::dl_load_file($library, 0)
    or die 'dl_load_file failed: ' . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, 'npt_main')
    or die 'dl_find_symbol failed: ' . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub('main::npt_main', $symbol);
npt_main();  # Exits the process.
