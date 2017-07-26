#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;

=head1 Index Loop Demo

This script demonstrates using 2 loops to iterate  through a
set to compare all entries to the others without duplication.

There is one exception though - when the last entry 'd' is reached 
in the outer loop, we want to have it compared to only the first entry.

This step is done in Index::Compare to ensure the final index 
for a table is included in the CSV output by comparint to the first.

Expected output shown here:

idxAry: 3
idxBase: 0
a : b
a : c
a : d
idxBase: 1
b : c
b : d
idxBase: 2
c : d
idxBase: 3
d : a


=cut


my @idxAry=qw(a b c d);

#print Dumper(\@idxAry);

print "idxAry: $#idxAry\n";

for ( my $idxCounter = 0; $idxCounter <= $#idxAry; $idxCounter++ ) {

	my $idxBase=$idxCounter;
	print "idxBase: $idxBase\n";

	#for ( my $idxCounter2 = $idxBase + 1; $idxCounter2 <= $#idxAry; $idxCounter2++ ) {
	
	my @bc=($idxBase+1 .. $#idxAry);

	if ($idxCounter == $#idxAry) { @bc=(0) }
	
	foreach my $idxCounter2 ( @bc ) {

		my $compIdx = $idxCounter2;

		#print "$idxCounter : $idxCounter2\n";
		print "$idxAry[$idxBase] : $idxAry[$compIdx]\n";

	} 

	#print "Action in outer loop\n" ; #unless $idxCounter == $#idxAry ;
}


