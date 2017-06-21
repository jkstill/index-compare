
package Generic;


use strict;
use warnings;

use Exporter qw(import);
our @ISA =   qw(Exporter);
our @EXPORT = qw(getPassword seriesSum compareAry closeSession);


sub getPassword();
sub seriesSum($);
sub compareAry ($$$$$);
sub closeSession($);

sub getPassword() {

	local $SIG{__DIE__} = sub {system('stty','echo');print "I was killed\n"; die }; # killed
	local $SIG{INT} = sub {system('stty','echo');print "I was interrupted\n"; die }; # CTL-C
	local $SIG{QUIT} = sub {system('stty','echo');print "I was told to quit\n"; die }; # ctl-\

	# this clearly does not work on non *nix systems
	# Oracle Perl does not come with Term::ReadKey, so doing this hack instead
	print "Enter password: " if -t;
	system('stty','-echo') if -t; #Hide console input for what we type - only if on a terminal
	chomp(my $password=<STDIN>);
	system('stty','echo') if -t; #Unhide console input for what we type - only if on a terminal
	print "\n" if -t;
	return $password;
}

=head1 seriesSum
 sum the values in a series 
 series assumed to start with 1 and end with passed value
 the real math for this: nCr = n! / (r! * (n -r)!)
 however this is a shortcut that works for this sequential series that begins with 1

 the purpose of this is to find the number of pairs that can be made from a set of data
 in this case comparing 2 indexes to each other
 this code predicts the number of comparisons to make

 test code:
  for (my $n=2; $n<7; $n++) {
	  print "$n: ", seriesSum($n), "\n"
  }

=cut 

sub closeSession ($) {
	my $dbh = shift;
	$dbh->rollback;
	$dbh->disconnect;
}

sub seriesSum ($){
	my ($boundary) = @_;
	my $sum=0;
	$sum += $_ for (1..($boundary-1));
	return $sum;
}

=head1 compareAry

 compare 2 arrays
 expects 5 arguments - pass as refs
 array to compare # 1
 array to compare # 2
 array containing interecting columns
 array containing columns found in 1 but not in 2
 array containing columns found in 2 but not in 1

 the intersection and diff arrays will be populated by this function
 ary1Diff: all elements appearing in ary1 but not in ary2
 ary2Diff: all elements appearing in ary2 but not in ary1
 intersect: elements common to both

=cut

sub compareAry ($$$$$){
	my ($ary1, $ary2, $intersect, $ary1Diff, $ary2Diff) = @_;
	
	my $debug = 0;

	print "Array 1:", Dumper($ary1) if $debug;
	print "Array 2:", Dumper($ary2) if $debug;

	my %count = ();

	my %ary1Keys = map { $_ => 'COL' } @{$ary1};
	my %ary2Keys = map { $_ => 'COL' } @{$ary2};

	print 'ary1Keys ' , Dumper(\%ary1Keys) if $debug;
	print 'ary2Keys ' , Dumper(\%ary2Keys) if $debug;

	foreach my $element (@{$ary1}, @${ary2}) { $count{$element}++ }

	foreach my $idxKey (sort keys %count) {
		print "idxKey: $idxKey\n" if $debug;
		if ($count{$idxKey} > 1) {
			push @{$intersect}, $idxKey;
		} else {
			# assign to correct diff array
			if (exists $ary1Keys{$idxKey} ) { push @{$ary1Diff}, $idxKey}
			else {push @{$ary2Diff}, $idxKey}
			;
		}
	}
	
	print 'Intersect: ', Dumper($intersect) if $debug;
	print 'Ary1 Diff: ', Dumper($ary1Diff) if $debug;
	print 'Ary2 Diff: ', Dumper($ary2Diff) if $debug;
	print 'Count: ', Dumper(\%count) if $debug;


}

1;

