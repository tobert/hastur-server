#!/usr/bin/perl

=head1 NAME

zones2cassandra.pl - parse zones files and write reverse mappings to Cassandra

=head1 DESCRIPTION

We assign CNAME's to pretty much all of our hosts that are human-readable.  The hosts
rarely have these useful names consistently mapped, so it's safest to map to the CNAME
using a reverse mapping built from our zone files.

This is written in perl instead of ruby because most of the DNS side already existed
and the perl parser is more reliable.

 zones2cassandra.pl -h hastur-cassandra1 -p 9202 -z $CODE_ROOT/dns/zones/pri/foo.zone

=head1 SYNOPSIS

 zones2cassandra.pl -z <zonefile> [-h localhost] [-p 9160] [-k Hastur]
 zones2cassandra.pl --zonefile <zonefile> [--host localhost] [--port 9160] [--keyspace Hastur]
   --zonefile <filename> BIND DNS zonefile to parse and write to Cassandra
   --host <hostname> Cassandra hostname to connect to
   --port <port> Cassandra RPC port
   --keyspace <keyspace> Cassandra keyspace to write to

=cut

use strict;
use warnings;
use Net::DNS::ZoneFile::Fast;
use File::Basename;
use Data::Dumper;
use IO::String;
use File::Slurp;
use Cassandra::Lite;
use DateTime;
use Getopt::Long;
use Pod::Usage;

pod2usage(-exit => 1) if (@ARGV == 0);

our($opt_keyspace, $opt_host, $opt_port, @opt_zonefile, $opt_help, $opt_debug);
GetOptions(
  "k:s" => \$opt_keyspace, "keyspace:s" => \$opt_keyspace,
  "h:s" => \$opt_host,     "host:s"     => \$opt_host,
  "p:s" => \$opt_port,     "port:s"     => \$opt_port,
  "z:s" => \@opt_zonefile, "zonefile:s" => \@opt_zonefile,
  "d"   => \$opt_debug,    "debug"      => \$opt_debug,
                           "help"       => \$opt_help
);

our $keyspace = $opt_keyspace || "Hastur";
our $host     = $opt_host     || "localhost";
our $port     = $opt_port     || 9160;

pod2usage(-exit => 0) if ($opt_help);
pod2usage(-message => "you must specify at least one zonefile", -exit => 1)
  unless @opt_zonefile > 0;

our $c = Cassandra::Lite->new(
    keyspace    => $keyspace,
    server_port => $port,
    server_name => $host,
    consistency_level_write => 'TWO'
);

our $today_usec = DateTime->today->epoch * 1_000_000;

print "Generating row $keyspace/LookupByKey/cnames-$today_usec from @opt_zonefile ...\n";

our %names;
foreach my $zonefile ( @opt_zonefile ) {
    my $path = dirname($zonefile);

    # read the data in and remove inconvenient lines like includes
    # which break the parser for now
    my $zone_txt = read_file($zonefile);
    $zone_txt =~ s/\$include[^\n]+\n//gi;

    my $fh = IO::String->new($zone_txt);
    my $rr = Net::DNS::ZoneFile::Fast::parse( fh => $fh );

    foreach my $r ( @$rr ) {
        if ( $r->type eq 'CNAME' ) {
            my $host = $r->rdatastr;
               $host =~ s/\.$//;

            next if exists $names{$host};
            $names{$host} = $r->name;
        }
    }
}

print "Writing to Cassandra $keyspace/LookupByKey/cnames-$today_usec ...\n";

if ($opt_debug) {
  print Dumper(\%names);
}

$c->put("LookupByKey", "cnames-$today_usec", \%names);

