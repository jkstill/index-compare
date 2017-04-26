

use strict;
use warnings;

use DBI;
use Data::Dumper;

my $dbh = DBI->connect(
	'dbi:Oracle:oravm' ,
	'sys', 'grok',
	{
		RaiseError => 1,
		AutoCommit => 0,
		ora_session_mode => 2
	}
	);

die "Connect to  oracle failed \n" unless $dbh;

my $debug=1;


sub seriesSum($);
sub compareAry ($$$$$);


my $schema2Chk = 'JKSTILL';

my $tabSql = q{select
table_name
from dba_tables
where owner = ?
	and table_name not like 'DR$%$I%' -- Text Indexes
order by table_name
};

my $idxSql = q{select
index_name
from dba_indexes
where owner = ?
	and table_name = ? 
	and index_name not like 'SYS_%$$' -- LOB segments
order by index_name
};

my $colSql = q{select
	index_name, listagg(column_name,',') within group (order by column_position) column_list
from dba_ind_columns
where index_owner = ?
	and table_owner = ?
	and table_name = ?
group by index_name
order by index_name
};

my $tabSth = $dbh->prepare($tabSql,{ora_check_sql => 0});
my $idxSth = $dbh->prepare($idxSql,{ora_check_sql => 0});
my $colSth = $dbh->prepare($colSql,{ora_check_sql => 0});

=head1 %colData

 column data will look like this

  my %colData = (
	  'SHR_INFO_DESID_IDX' =>             ['DEST_ID'],
	  'SHR_INFO_PK' =>                    ['SITE_ID','CLIENT_ID','DEST_ID','ID'],
	  'SHR_INFO_SIT_CLI_TRU_DES_IDX' =>   ['SITE_ID','CLIENT_ID','SYS_NC00015$','DEST_ID'],
	  'SHR_INFO_SIT_CLI_USE_KEY_IDX' =>   ['SITE_ID','CLIENT_ID','USER_KEY'],
	  'SHR_INFO_SI_CL_DE_US_GU_UR_UK' =>  ['SITE_ID','CLIENT_ID','DEST_ID','USER_ID','GUEST_ID','URL'],
	  'SHR_INFO_SI_CL_DE_US_KE_UR_UK' =>  ['SITE_ID','CLIENT_ID','DEST_ID','USER_KEY','URL'],
	  'SHR_INFO_SI_CL_DE_US_TR_IDX' =>    ['SITE_ID','CLIENT_ID','DEST_ID','USER_ID','SYS_NC00015$'],
  );

=cut

$tabSth->execute($schema2Chk);

my @tables;
while ( my $table = $tabSth->fetchrow_arrayref) { push @tables, $table->[0]}

die "No tables found for $schema2Chk!\n" unless @tables;

if ($debug) {
	print Dumper(\@tables);
	#$dbh->disconnect;
	#exit;
}

# start of main loop - process tables
foreach my $el ( 0 .. $#tables ) {
	my $tableName = $tables[$el];


	#$idxSth->execute($schema2Chk,$tableName);
	$colSth->execute($schema2Chk, $schema2Chk, $tableName);

	my %colData=();
	my @indexes=();
	while ( my $colAry = $colSth->fetchrow_arrayref) { 
		my ($indexName,$columnList) = @{$colAry};

		print "Cols:  $columnList\n";

		push @{$colData{$indexName}},split(/,/,$columnList);

	}

	print 'Col Data: ', Dumper(\%colData);

	next;

	my $indexCount = $#indexes + 1;

	print Dumper(\%colData);
	print Dumper(\@indexes);

	print "Index Count: $indexCount\n";

	my $numberOfComparisons = seriesSum($indexCount);

	print "Number of Comparisons: $numberOfComparisons\n";

	my $indexesComparedCount=0;

	# compare from first index to penultimate index as first of a pair to compare
	for (my $idxBase=0; $idxBase < ($indexCount-1); $idxBase++ ) {
		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		for (my $compIdx=$idxBase+1; $compIdx < ($indexCount); $compIdx++ ) {

			my $debug=0;

			print '#' x 120, "\n";
			print "Comparing $indexes[$idxBase] -> $indexes[$compIdx]\n";
			$indexesComparedCount++;

			print "IDX 1: ", Dumper($colData{$indexes[$idxBase]}) if $debug;
			print "IDX 2: ", Dumper($colData{$indexes[$compIdx]}) if $debug;

			my @intersection = ();
			my @idx1Diff = ();
			my @idx2Diff = ();

			compareAry($colData{$indexes[$idxBase]}, $colData{$indexes[$compIdx]}, \@intersection, \@idx1Diff, \@idx2Diff);

			if ($debug) {
				print "DIFF 1: ", Dumper(\@idx1Diff);
				print "DIFF 2: ", Dumper(\@idx2Diff);
				print "INTERSECT: ", Dumper(\@intersection);
			}

			print "\nColumns found only in $indexes[$idxBase]\n";
			print "\n\t", join("\n\t",sort @idx1Diff),"\n\n";

			print "Columns found only in $indexes[$compIdx]\n";
			print "\n\t", join("\n\t",sort @idx2Diff),"\n\n";

			print "Columns found in both\n";
			print "\n\t", join("\n\t",sort @intersection),"\n\n";



		}
	}

	print "Total Comparisons Made: $indexesComparedCount\n";

}

$dbh->disconnect;


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


