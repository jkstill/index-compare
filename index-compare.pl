
# run with $ORACLE_HOME/perl/bin/perl script-name

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Getopt::Long;
use IO::File;

my $debug=0;
sub closeSession($);
sub getPassword();
sub seriesSum($);
sub compareAry ($$$$$);
sub getIdxPairInfo($$$);
sub csvPrint($$$$);


my $db=undef; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=0;
my $password=undef;
my $username=undef;
my $sysdba=0;
my $schema2Chk = 'SCOTT';
my $csvFile=undef;
my $csvDelimiter=',';
my $colnameDelimiter='|'; # used to separate columns and SQL statements in the CSV output field - must be different than csvDelimiter
my $csvOut=0;

my %csvColByID = (
	0	=>"Table Name",
	1	=>"Index Name",
	2	=>"Compared To",
	3	=>"Size",
	4	=>"Constraint Type",
	5	=>"Redundant",
	6	=>"Column Dup%",
	7	=>"Known Used",
	8	=>"Drop Candidate",
	9	=>"Drop Immediately",
	10	=>"Create ColGroup",
	11	=>"Columns", # must always be penultimate field
	12	=>"SQL", # must always be last field
);

my %csvColByName = map { $csvColByID{$_} => $_ } keys %csvColByID;

#print 'csvColByID ' . Dumper(\%csvColByID);
#print 'csvColByName: ' . Dumper(\%csvColByName);

# the table containing the names of known used indexes
my $idxChkTable='avail.used_ct_indexes';

# let us know if this percent or more of leading indexes are shared
my $idxRatioAlertThreshold = 75;

my $traceFile='- no file specified';
my $opLineLen=80;
my $help=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"schema=s" => \$schema2Chk,
		"index-ratio-alert-threshold=i" => \$idxRatioAlertThreshold,
		"csv-file=s" => \$csvFile,
		"csv-delimiter=s" => \$csvDelimiter,
		"column-delimiter=s" => \$colnameDelimiter,
		"sysdba!" => \$sysdba,
		"debug!" => \$debug,
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

$csvOut = defined($csvFile) ? 1 : 0;

if ($csvDelimiter eq $colnameDelimiter ) {
	print "CSV delimiter must be different than column delimiter\n";
	exit 1;
}

my $csvFH=undef;
if ($csvOut) {
	$csvFH = IO::File->new($csvFile,'w');
	die "Could not create $csvFile\n" unless $csvFH;
}

if ($csvOut) {

	my @header = map { $csvColByID{$_} } sort { $a <=> $b } keys %csvColByID;
	#print 'Header : ' , Dumper(\@header);

	my $SQL = pop @header;
	my $colNames = pop @header;
	push @header, [$colNames];
	push @header, [$SQL];

	csvPrint($csvFH,$csvDelimiter,$colnameDelimiter,\@header);
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


my $tabSql = q{select
table_name
from dba_tables
where owner = ?
	and table_name not like 'DR$%$I%' -- Text Indexes
order by table_name
};

my $idxInfoSql = q{with cons_idx as (
   select /*+ no_merge */
      table_name, index_name , constraint_name, constraint_type
   from dba_constraints
   where owner = ?
   and constraint_type in ('R','U','P')
   and index_name is not null
), 
-- going to assume all tablespaces are db_block_size
block_size as (
	select value block_size from v$parameter where name = 'db_block_size'
)
select i.table_name, i.index_name
   , i.leaf_blocks * bs.block_size bytes
   , nvl(idx.constraint_name , 'NONE') constraint_name
   , nvl(idx.constraint_type , 'NONE') constraint_type
from dba_indexes i
natural join block_size bs
left outer join cons_idx idx on idx.table_name = i.table_name
   and idx.index_name = i.index_name
where i.owner = ?
	and i.index_name = ?
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

# SQL to check the table of known used indexes
my $idxChkSql = qq{select
	index_name
from $idxChkTable
where index_name = ?
};


my $tabSth = $dbh->prepare($tabSql,{ora_check_sql => 0});
my $idxInfoSth = $dbh->prepare($idxInfoSql,{ora_check_sql => 0});
my $idxChkSth = $dbh->prepare($idxChkSql,{ora_check_sql => 0});
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

my $csvInclude = $csvOut ? 1 : 0;
# indexes will be included in CSV output when the idxRatioAlertThreshold is met
my %csvIndexes=(); 

# start of main loop - process tables
foreach my $el ( 0 .. $#tables ) {
	my $tableName = $tables[$el];

	#my $debug=0;

	print '#' x 120, "\n";
	print "Working on table $tableName\n";

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
	my @idxInfo=(); # temp storage for data to put in %csvIndexes

	# compare from first index to penultimate index as first of a pair to compare
	for (my $idxBase=0; $idxBase < ($indexCount-1); $idxBase++ ) {


		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		for (my $compIdx=$idxBase+1; $compIdx < ($indexCount); $compIdx++ ) {

			#my $debug=0;

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

			$idxInfo[$csvColByName{'Table Name'}] = $tableName;
			$idxInfo[$csvColByName{'Index Name'}] = $indexes[$idxBase];
			$idxInfo[$csvColByName{'Compared To'}] = $indexes[$compIdx];
			$idxInfo[$csvColByName{'Size'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Constraint Type'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Redundant'}] = 'N';
			$idxInfo[$csvColByName{'Column Dup%'}] = 0;
			$idxInfo[$csvColByName{'Known Used'}] = 'N';
			$idxInfo[$csvColByName{'Drop Candidate'}] = 'N';
			$idxInfo[$csvColByName{'Drop Immediately'}] = 'N';
			$idxInfo[$csvColByName{'Create ColGroup'}] = 'NA';
			$idxInfo[$csvColByName{'Columns'}] = $colData{$indexes[$idxBase]};
			$idxInfo[$csvColByName{'SQL'}] = [];


			if ($leadingColCount > 0 ) {
				my $leastColSimilarCountRatio = ( $leadingColCount / ($leastColCount+1)  ) * 100;
				my $leastIdxNameLen = length($leastIdxName);
				my $mostIdxNameLen = length($mostIdxName);
				my $attention='';

				$idxInfo[$csvColByName{'Redundant'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';
				$idxInfo[$csvColByName{'Column Dup%'}] = $leastColSimilarCountRatio;
				$idxInfo[$csvColByName{'Drop Immediately'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';

				if ( $leastColSimilarCountRatio >= $idxRatioAlertThreshold ) {
					$attention = '====>>>> ';
					$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
				}
				printf ("%-10s The leading %3.2f%% of columns for index %${leastIdxNameLen}s are shared with %${mostIdxNameLen}s\n", $attention, $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);
				#printf ("The leading %3.2f%% of columns for index %30s are shared with %30s\n", $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);


				if ( isIdxUsed($idxChkSth,$indexes[$idxBase]) ) {
					print "Index $indexes[$idxBase] is known to be used in Execution Plans\n";
					$idxInfo[$csvColByName{'Known Used'}] = 'Y';
				} else {
					$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
				}

				if ( isIdxUsed($idxChkSth,$indexes[$compIdx]) ) {
					print "Index $indexes[$compIdx] is known to be used in Execution Plans\n";
				}

				if ( $leastColSimilarCountRatio >= $idxRatioAlertThreshold ) {
					# check to see if either index is known to support a constraint
					my %idxPairInfo = (
						$leastIdxName => undef,
						$mostIdxName => undef
					);
					getIdxPairInfo($schema2Chk,$idxInfoSth,\%idxPairInfo);
					#print Dumper(\%idxPairInfo);


					# report if any constraints use one or both of the indexes
					foreach my $idxName ( keys %idxPairInfo ) {
						# only 4 possibilities at this time - NONE, R, U, and P
						my ($idxBytes, $constraintName, $constraintType) = @{$idxPairInfo{$idxName}};
						
						my $idxNameLen = length($idxName);
						printf ("The index %${idxNameLen}s is %9.0f bytes\n", $idxName, $idxBytes);

						if ($idxName eq $indexes[$idxBase] ) {
							$idxInfo[$csvColByName{'Size'}] = $idxBytes;
							$idxInfo[$csvColByName{'Constraint Type'}] = $constraintType;
						}

						if ( $constraintType eq 'NONE' ) {
							print "The index $idxName does not appear to support any constraints\n";
						} elsif ( $constraintType eq 'R' ) { # foreign key
								print "The index $idxName supports Foreign Key $constraintName\n";
						} elsif ( $constraintType eq 'U' ) { # unique key
								print "The index $idxName supports Unique Key $constraintName\n";
						} elsif ( $constraintType eq 'P' ) { # primary key
								print "The index $idxName supports Primary Key $constraintName\n";
						} else { 
							warn "Unknown Constraint type of $constraintType!\n";
						}
					}
				}
			}
		}

		print qq{

Debug: csvIndexes
idxInfo[csvColByName{'Table Name'}]: $idxInfo[$csvColByName{'Table Name'}]
idxInfo[csvColByName{'Index Name'}] : $idxInfo[$csvColByName{'Index Name'}] 

} if $debug;

		print 'idxInfo: ' , Dumper(\@idxInfo) if $debug;

		push @{$csvIndexes{ $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] }}, @idxInfo;
	}


	print "\tTotal Comparisons Made: $indexesComparedCount\n\n";

	print "\t!! Number of Comparisons made was $indexesComparedCount - should have been $numberOfComparisons !!\n" if ($numberOfComparisons != $indexesComparedCount );

}

closeSession($dbh);

print 'csvIndexes: ' , Dumper(\%csvIndexes);

if ( $csvOut ) {
	foreach my $tabIdx ( sort keys %csvIndexes ) {
		csvPrint($csvFH,$csvDelimiter,$colnameDelimiter,$csvIndexes{$tabIdx});
	}
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
	
	#my $debug = 0;

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

  --index-ratio-alert-threshold 
					 the threshold at which to report on 2 indexes having the same leading columns
					 default is 75 - if 75% of the leading columns of the index with the least number 
					 of columns are the same as the other column, provide extra reporting.

	 --sysdba    connect as sysdba

	 --csv-file          File name for CSV output.  There will be no CSV output unless the file is named
	 --csv-delimiter     Delimiter to separate fields in CSV output - defaults to ,
	 --column-delimiter  Delimiter to separate column names in CSV field for index column names - defaults to |

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

sub getIdxPairInfo($$$) {
	my $schema = shift;
	my $sth = shift;
	my $idxHash = shift;

	# prepopulated with 2 index names as keys
	# and array containing schema name
	foreach my $idx ( keys %{$idxHash} ) {
		
		# idxInfoSql is global
		#
		#print "DBI-DEBUG: index name: $idx\n";

		$sth->execute($schema, $schema, $idx);
		#my ($indexName, $bytes, $constraintType) = $idxSth->fetchrow;
		#push @{$idxHash->{$idx}}, $sth->fetchrow_arrayref;

		while (my $ary = $sth->fetchrow_arrayref ) {
			#print "DBI-DEBUG: ", join(' - ', @{$ary}), "\n";
			# bytes, constraint_name, constraint_type
			push @{$idxHash->{$idx}}, ($ary->[2], $ary->[3], $ary->[4]);
			
		}
		$sth->finish;


	}

	#print "DEBUG: getIdxPairInfo" , Dumper($idxHash);

}

# check the usage table to see if the index is known to be used.
sub isIdxUsed {
	my $sth = shift;
	my $idxName = shift;
	$sth->execute($idxName);

	my $result = $sth->fetchrow_arrayref;
	$sth->finish;

	#if ( defined($sth->fetchrow_arrayref)) { return 1 }
	if (defined($result)){ return 1 }
	else { return 0}

}

=head1 csvPrint

 Print to CSV file
 pass the file handle, csv delimiter, columm/sql delimiter and array ref of data
 the last two elements in the array are array refs (column names an SQL statements


=cut


sub csvPrint($$$$) {
	my $fh = shift;
	my $csvDelimiter = shift;
	my $colnameDelimiter = shift;
	my $ary = shift;

	#print 'ary: ', Dumper($ary);

	my $lastEl = $#{$ary};

	#print "DEBUG - lastEl: $lastEl\n";
	#print 'ary: ', Dumper($ary->[$lastEl-1]);

	my $colNames = join("$colnameDelimiter",@{$ary->[$lastEl-1]});
	my $sqlStatements = join("$colnameDelimiter",@{$ary->[$lastEl]});

	print $fh join($csvDelimiter,@{$ary}[0..($lastEl-2)]),$csvDelimiter;
	# print Column names
	print $fh "${colNames}" if defined($colNames);
	print $fh $csvDelimiter;
	# print SQL
	print $fh "${sqlStatements}\n";

}









