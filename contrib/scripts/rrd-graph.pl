#!/usr/bin/perl
# Copyright 2010 Tomas Carnecky

use RRDs;
use LWP::Simple;
use JSON;

my $rrd = '/var/lib/rrd/traffic.rrd';
my $img = '/var/www/stuff/rrd';
my $url = 'http://localhost:9091/transmission';

&UpdateDatabase();

sub UpdateDatabase
{
	if (! -e "$rrd")
	{
		RRDs::create "$rrd",
			"-s 300",

			"DS:rxto:DERIVE:600:0:12500000",
			"DS:rxtr:DERIVE:600:0:12500000",
			"DS:txtr:DERIVE:600:0:12500000",
			"DS:txto:DERIVE:600:0:12500000",

			"RRA:AVERAGE:0.5:1:576", #  5 min for  2 days
			"RRA:AVERAGE:0.5:6:672"; # 30 min for 14 days
	}

	# get the total network utilization
	my $ifconf = `/sbin/ifconfig eth0`;

	my ($rxto) = $ifconf =~ m/RX bytes:(\d+)/;
	my ($txto) = $ifconf =~ m/TX bytes:(\d+)/;

	# see what was consumed by transmission
	my $content = get($url . '/rpc/?method=session-stats');
	my $stats = jsonToObj($content)->{'arguments'}->{'current-stats'};

	# insert values into rrd
	RRDs::update "$rrd",
		"-t", "rxto:rxtr:txtr:txto",
		"N:$rxto:$stats->{'downloadedBytes'}:$stats->{'uploadedBytes'}:$txto";

	&CreateGraph("2days");
}

sub CreateGraph
{
	RRDs::graph "$img/traffic.png",
		"-s -$_[0]",
		"-t Network Traffic",
		"--lazy",
		"-h", "200", "-w", "400",
		"-l 0",
		"-c", "SHADEA#f8faf7", "-c", "SHADEB#f8faf7",
		"-c", "BACK#f8faf7", "-c", "CANVAS#cccccc",
		"-c", "FONT#666666", "-c", "GRID#888a85",
		"-c", "MGRID#777974", "-c", "ARROW#888a85",
		"-a", "PNG",
		"-v bytes/sec",

		"DEF:in=$rrd:rxto:AVERAGE",
		"DEF:out=$rrd:txto:AVERAGE",
		"DEF:inT=$rrd:rxtr:AVERAGE",
		"DEF:outT=$rrd:txtr:AVERAGE",
		"CDEF:out_neg=out,-1,*",
		"CDEF:out_negT=outT,-1,*",

		"AREA:in#204a87",
		"AREA:inT#cc0000",
		"AREA:out_neg#204a87",
		"AREA:out_negT#cc0000",

		"LINE1:in#204a87:Total     ",
		"GPRINT:in:LAST:%6.1lf%S /", "GPRINT:out:LAST:%6.1lf%S\\n",

		"LINE1:inT#cc0000:BitTorrent",
		"GPRINT:inT:LAST:%6.1lf%S /", "GPRINT:outT:LAST:%6.1lf%S\\n",

		"HRULE:0#666666";

	if ($ERROR = RRDs::error) {
		print "$0: unable to generate $_[0] $_[1] traffic graph: $ERROR\n"; 
	}
}

