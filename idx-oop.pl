
# run with $ORACLE_HOME/perl/bin/perl script-name

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Getopt::Long;
use IO::File;

use Index::Compare;
use Generic qw(getPassword seriesSum compareAry closeSession);

my $debug=1;
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

# SQL statements are all written to separate files
# some SQL requires commas which messes up our comma delimited file
# also makes the spreadsheet much more usable

my %dirs = (
	'colgrpDDL' => 'column-group-ddl',
	'indexDDL' => 'index-ddl',
);

# create dirs as needed

foreach my $dir ( keys %dirs ) {
	if ( ! -d $dirs{$dir} ) {
		die "Could not create $dirs{$dir}\n" unless mkdir $dirs{$dir};
	}
}

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
	10	=>"Create ColGroup", # 'NA' or 'Y'
	11	=>"Columns", # must always be the last field
	#12	=>"SQL", # must always be last field
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

	#my $SQL = pop @header;
	my $colNames = pop @header;
	push @header, [$colNames];
	#push @header, [$SQL];

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


#my $idxInfoSth = $dbh->prepare($idxInfoSql,{ora_check_sql => 0});
#my $idxChkSth = $dbh->prepare($idxChkSql,{ora_check_sql => 0});

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

my $compare = new Index::Compare (
	DBH => $dbh,
	SCHEMA => $schema2Chk,
	IDX_CHK_TABLE => $idxChkTable,
	RATIO	=> $idxRatioAlertThreshold
);

#print Dumper($compare);

my $csvInclude = $csvOut ? 1 : 0;
# indexes will be included in CSV output when the idxRatioAlertThreshold is met
my %csvIndexes=(); 

# start of main loop - process tables
TABLE: while ( my $tableName = $compare->getTable() ) {

	#my $debug=0;

	print '#' x 120, "\n";
	print "Working on table $tableName\n";

	my %colData=();
	my @indexes=();

	$compare->getIdxColInfo (
		TABLE => $tableName,
		COLHASH => \%colData,
		IDXARY => \@indexes
	);

	print 'Col Data: ', Dumper(\%colData) if $debug;
	print 'Indexes: ', Dumper(\@indexes) if $debug;

	#next;

	# returns 0 if only 1 index
	print "Number of indexes: " , $#indexes ,"\n";
	if ($#indexes < 1 ) {
		print "Skipping comparison as there is only 1 index on $tableName\n";
		next TABLE;
	}

	print '%colData:  ' , Dumper(\%colData) if $debug;
	print '@indexes:  ' , Dumper(\@indexes) if $debug;
	
	#next; # debug - skip code

	my $numberOfComparisons = seriesSum($#indexes + 1);

	print "\tNumber of Comparisons to make: $numberOfComparisons\n";

	my $indexesComparedCount=0;
	my @idxInfo=(); # temp storage for data to put in %csvIndexes

	# compare from first index to penultimate index as first of a pair to compare
	IDXCOMP: for (my $idxBase=0; $idxBase < ($#indexes); $idxBase++ ) {

		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		for (my $compIdx=$idxBase+1; $compIdx < ($#indexes + 1); $compIdx++ ) {

			#my $debug=0;

			# do not compare an index to itself
			# this can happen when a single index is supporting two or more constraints, such as Unique and Primary
			# possibly only if it is also the only index
			# putting code above to skip these
			my $indexesIdentical=0;
			if ($indexes[$idxBase] eq $indexes[$compIdx]) {
				print "Indexes $indexes[$idxBase] and $indexes[$compIdx] are identical\n";
				$indexesIdentical=1;
				next IDXCOMP; # naked 'next' was going to the outer loop - dunno why
			}

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
			#$idxInfo[$csvColByName{'SQL'}] = [];


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


			if ( $compare->isIdxUsed($indexes[$idxBase]) ) {
				print "Index $indexes[$idxBase] is known to be used in Execution Plans\n";
				$idxInfo[$csvColByName{'Known Used'}] = 'Y';
			} else {
				$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
			}

			if ( $compare->isIdxUsed($indexes[$compIdx]) ) {
				print "Index $indexes[$compIdx] is known to be used in Execution Plans\n";
			}

			# check to see if either index is known to support a constraint
			my %idxPairInfo = (
				$leastIdxName => undef,
				$mostIdxName => undef
			);
			$compare->getIdxPairInfo(\%idxPairInfo);
			#print '%idxPairInfo: ' , Dumper(\%idxPairInfo);


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
		} # inner index loop

		print qq{

Debug: csvIndexes
idxInfo[csvColByName{'Table Name'}]: $idxInfo[$csvColByName{'Table Name'}]
idxInfo[csvColByName{'Index Name'}] : $idxInfo[$csvColByName{'Index Name'}] 

		} if $debug;

		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' invisible;';
		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' visible;';

		my $idxDDLFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-invisible.sql';
		my $idxDDLFh = IO::File->new("$dirs{'indexDDL'}/$idxDDLFile",'w');
		die "Could not create $idxDDLFile\n" unless $idxDDLFh;
		print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' invisible;';

		$idxDDLFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-visible.sql';
		$idxDDLFh = IO::File->new("$dirs{'indexDDL'}/$idxDDLFile",'w');
		die "Could not create $idxDDLFile\n" unless $idxDDLFh;
		print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' visible;';

		close $idxDDLFh;


=head1 create column group DDL as necessary
		
 The optimizer may be using statistics gathered on index columns during optimization
 even if that index is never used in an execution plan.

 When an index is a drop candidate, and there are no duplicated leading columns, include code to create extended stats
	

=cut
		
		if ( 
			$idxInfo[$csvColByName{'Drop Candidate'}] eq 'Y' 
				and 
			$idxInfo[$csvColByName{'Column Dup%'}] == 0
		) {
			my $columns = join(',',@{$idxInfo[$csvColByName{'Columns'}]});
			my $colgrpDDL = qq{declare extname varchar2(30); begin extname := dbms_stats.create_extended_stats ( ownname => '$schema2Chk', tabname => '$tableName', extension => '($columns)'); dbms_output.put_line(extname); end;};

			print "ColGrp DDL:  $colgrpDDL\n";

			my $colgrpFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-colgrp.sql';

			my $colgrpFH = IO::File->new("$dirs{'colgrpDDL'}/$colgrpFile",'w');
			die "Could not create $colgrpFile\n" unless $colgrpFH;

			print $colgrpFH "$colgrpDDL\n";
			close $colgrpFH;

			$idxInfo[$csvColByName{'Create ColGroup'}] = 'Y';
		}

		print 'idxInfo: ' , Dumper(\@idxInfo) if $debug;

		push @{$csvIndexes{ $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] }}, @idxInfo;
	} # outer index loop


	print "\tTotal Comparisons Made: $indexesComparedCount\n\n";

	#print "\t!! Number of Comparisons made was $indexesComparedCount - should have been $numberOfComparisons !!\n" if ($numberOfComparisons != $indexesComparedCount );

}

closeSession($dbh);

print 'csvIndexes: ' , Dumper(\%csvIndexes);

if ( $csvOut ) {
	foreach my $tabIdx ( sort keys %csvIndexes ) {
		csvPrint($csvFH,$csvDelimiter,$colnameDelimiter,$csvIndexes{$tabIdx});
	}
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

	#my $colNames = join("$colnameDelimiter",@{$ary->[$lastEl-1]});
	#my $sqlStatements = join("$colnameDelimiter",@{$ary->[$lastEl]});
	my $colNames = join("$colnameDelimiter",@{$ary->[$lastEl]});

	print $fh join($csvDelimiter,@{$ary}[0..($lastEl-1)]),$csvDelimiter;
	# print Column names
	print $fh "${colNames}" if defined($colNames);
	print $fh "\n";
	#print $fh $csvDelimiter;
	# print SQL
	#print $fh "${sqlStatements}\n";

}









