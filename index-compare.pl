
# run with $ORACLE_HOME/perl/bin/perl script-name

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Getopt::Long;

my $debug=0;
sub closeSession($);
sub getPassword();
sub seriesSum($);
sub compareAry ($$$$$);


my $db=undef; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=0;
my $password=undef;
my $username=undef;
my $sysdba=0;
my $schema2Chk = 'SCOTT';


# simpler method of assigning defaults with Getopt::Long

my $traceFile='- no file specified';
my $opLineLen=80;
my $help=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"schema=s" => \$schema2Chk,
		"sysdba!" => \$sysdba,
		"password!" => \$getPassword,
		"h|help!" => \$help
) or die usage(1);

usage() if $help;

$sysdba=2 if $sysdba;
$schema2Chk = uc($schema2Chk);

if ($getPassword) {
	$password = getPassword();
	#print "Password: $password\n";
}

if ($debug) {
	print "Database: $db\n";
	print "Username: $username\n";
}

my $dbh = DBI->connect(
	"dbi:Oracle:${db}" , 
	$username,$password,
	#$username, $password,
	{
		RaiseError => 1,
		AutoCommit => 0,
		ora_session_mode => $sysdba
	}
	);

die "Connect to  oracle failed \n" unless $dbh;


# some internal config stuff
# let us know if this percent or more of leading indexes are shared
my $idxRatioAlertThreshold = 75;

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

unless (@tables) {
	closeSession($dbh);
	die "No tables found for $schema2Chk!\n";
}

if ($debug) {
	print Dumper(\@tables);
	# closeSession($dbh)
	#exit;
}

# start of main loop - process tables
foreach my $el ( 0 .. $#tables ) {
	my $tableName = $tables[$el];

	my $debug=0;

	print '#' x 120, "\n";
	print "Working on table $tableName\n";

	#$idxSth->execute($schema2Chk,$tableName);
	$colSth->execute($schema2Chk, $schema2Chk, $tableName);

	my %colData=();
	while ( my $colAry = $colSth->fetchrow_arrayref) { 
		my ($indexName,$columnList) = @{$colAry};

		#print "Cols:  $columnList\n";

		push @{$colData{$indexName}},split(/,/,$columnList);

	}

	my @indexes = sort keys %colData;
	print 'Col Data: ', Dumper(\%colData) if $debug;

	#next;

	my $indexCount = $#indexes + 1;

	print Dumper(\%colData) if $debug;
	print Dumper(\@indexes) if $debug;

	#print "Index Count: $indexCount\n";

	my $numberOfComparisons = seriesSum($indexCount);

	print "\tNumber of Comparisons to make: $numberOfComparisons\n";

	my $indexesComparedCount=0;

	# compare from first index to penultimate index as first of a pair to compare
	for (my $idxBase=0; $idxBase < ($indexCount-1); $idxBase++ ) {
		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		for (my $compIdx=$idxBase+1; $compIdx < ($indexCount); $compIdx++ ) {

			my $debug=0;

			print "\t",'=' x 100, "\n";
			print "\tComparing $indexes[$idxBase] -> $indexes[$compIdx]\n";

			print "\n\tColumn Lists:\n";
			printf("\t %30s: %-200s\n", $indexes[$idxBase], join(' , ', @{$colData{$indexes[$idxBase]}}));
			printf("\t %30s: %-200s\n", $indexes[$compIdx], join(' , ', @{$colData{$indexes[$compIdx]}}));

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

			print "\n\tColumns found only in $indexes[$idxBase]\n";
			print "\n\t\t", join("\n\t\t",sort @idx1Diff),"\n\n";

			print "\tColumns found only in $indexes[$compIdx]\n";
			print "\n\t\t", join("\n\t\t",sort @idx2Diff),"\n\n";

			print "\tColumns found in both\n";
			print "\n\t\t", join("\n\t\t",sort @intersection),"\n\n";

			my @idxCols1 = @{$colData{$indexes[$idxBase]}};
			my @idxCols2 = @{$colData{$indexes[$compIdx]}};

			# get least number of column count
			my ($leastColCount, $mostColCount);
			my ($leastIdxName, $mostIdxName);

			if ( $#idxCols1 < $#idxCols2 ) {
				$leastColCount = $#idxCols1;
				$mostColCount = $#idxCols2;
				$leastIdxName = $indexes[$idxBase];
				$mostIdxName = $indexes[$compIdx];
			} else {
				$leastColCount = $#idxCols2;
				$mostColCount = $#idxCols1;
				$leastIdxName = $indexes[$compIdx];
				$mostIdxName = $indexes[$idxBase];
			};

			my $leadingColCount = 0;
			foreach my $colID ( 0 .. $leastColCount ) {
				last unless ( $idxCols1[$colID] eq $idxCols2[$colID]);
				$leadingColCount++;
			}

			if ($leadingColCount > 0 ) {
				my $leastColSimilarCountRatio = ( $leadingColCount / ($leastColCount+1)  ) * 100;
				my $leastIdxNameLen = length($leastIdxName);
				my $mostIdxNameLen = length($mostIdxName);
				my $attention='';
				if ( $leastColSimilarCountRatio >= $idxRatioAlertThreshold ) {
					$attention = '====>>>> ';
				}
				printf ("%-10s The leading %3.2f%% of columns for index %${leastIdxNameLen}s are shared with %${mostIdxNameLen}s\n", $attention, $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);
				#printf ("The leading %3.2f%% of columns for index %30s are shared with %30s\n", $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);
			}

		}
	}

	print "\tTotal Comparisons Made: $indexesComparedCount\n\n";

	print "\t!! Number of Comparisons made was $indexesComparedCount - should have been $numberOfComparisons !!\n" if ($numberOfComparisons != $indexesComparedCount );

}

closeSession($dbh);


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

sub usage {

	my $exitVal = shift;
	use File::Basename;
	my $basename = basename($0);
	print qq{
$basename

usage: $basename - analyze schema indexes for redundancy

   $basename --database --username --password --schema scott

  --database do not specify for local SYSDBA connection (ORACLE_SID must be set)
  --schema   the database schema to analyze
  --username do not specify for local SYSDBA connection
  --password specifies that user will be asked for password
             this option does NOT accept a password

 --sysdba    connect as sysdba

examples here:

   $basename --schema SCOTT
   $basename --schema SCOTT --database orcl --password --sysdba

};

	exit eval { defined($exitVal) ? $exitVal : 0 };
}


sub getPassword() {

	local $SIG{__DIE__} = sub {system('stty','echo');print "I was killed\n"; die }; # killed
	local $SIG{INT} = sub {system('stty','echo');print "I was interrupted\n"; die }; # CTL-C
	local $SIG{QUIT} = sub {system('stty','echo');print "I was told to quit\n"; die }; # ctl-\

	# this clearly does not work on non *nix systems
	# Oracle Perl does not come with Term::ReadKey, so doing this hack instead
	print "Enter password: ";
	system('stty','-echo'); #Hide console input for what we type
	chomp(my $password=<STDIN>);
	system('stty','echo'); #Unhide console input for what we type
	print "\n";
	return $password;
}

sub closeSession ($) {
	my $dbh = shift;
	$dbh->rollback;
	$dbh->disconnect;
}


