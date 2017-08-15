
# run with $ORACLE_HOME/perl/bin/perl script-name

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Getopt::Long;
use IO::File;

use lib './lib';

use Index::Compare;
use Generic qw(getPassword  closeSession);

my $debug=0;
sub csvPrint($$$$);

my $db=''; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=0;
my $password='';
my $username='';
my $sysdba=0;
my $csvFile=undef;
my $csvDelimiter=',';
my $schema2Chk='%';
my $colnameDelimiter='|'; # used to separate columns and SQL statements in the CSV output field - must be different than csvDelimiter
my $csvOut=0;
# indexes will be included in CSV output when the idxRatioAlertThreshold is met
my %csvIndexes=(); 
# push all report output to an array
my @rptOut=();

# SQL statements are all written to separate files
# some SQL requires commas which messes up our comma delimited file
# also makes the spreadsheet much more usable
# 
# there is an option to disable either or both of these as
# databases with a very large number of objects will require a lot of extra time to generate these
# these are by default enabled and must be explicitly disabled
# --no-gen-ddl will disable both generate of both column group DDL and index DDL

my $genColGrpsDDL=1;
my $genIndexDDL=1;
my $genDDL=1;

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
		"idx-chk-table=s" => \$idxChkTable,
		"index-ratio-alert-threshold=i" => \$idxRatioAlertThreshold,
		"csv-file=s" => \$csvFile,
		"csv-delimiter=s" => \$csvDelimiter,
		"column-delimiter=s" => \$colnameDelimiter,
		"schema=s" => \$schema2Chk,
		"gen-column-groups!" => \$genColGrpsDDL,
		"gen-index-ddl!" => \$genIndexDDL,
		"gen-ddl!" => \$genDDL,
		"help!" => \$help,
		"sysdba!" => \$sysdba,
		"debug!" => \$debug,
		"password!" => \$getPassword,
) or die usage(1);

usage() if $help;

$sysdba=2 if $sysdba;

if ( ! $genDDL ) {
	$genColGrpsDDL=0;
	$genIndexDDL=0;
}

if ($debug ) {

	print "\n";
	print "Generate Column Groups: " , $genColGrpsDDL ? 'Yes' : 'No' , "\n";
	print "    Generate Index DDL: " , $genIndexDDL ? 'Yes' : 'No' , "\n";
	print "\n";

	#exit;
}

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


my $dbh = DBI->connect(
	"dbi:Oracle:${db}" , 
	$username,$password,
	{
		RaiseError => 1,
		AutoCommit => 0,
		ora_session_mode => $sysdba
	}
);

die "Connect to  oracle failed \n" unless $dbh;

my $compare = new Index::Compare (
	DBH => $dbh,
	IDX_CHK_TABLE => $idxChkTable,
	RATIO	=> $idxRatioAlertThreshold,
	SCHEMA => $schema2Chk,
	GEN_COLGRP_DDL => $genColGrpsDDL,
	GEN_INDEX_DDL => $genIndexDDL,
);


if ($csvOut) {
	my @header = $compare->buildCsvHdr;
	#print 'Header : ' , Dumper(\@header);
	my $colNames = pop @header;
	push @header, [$colNames];
	csvPrint($csvFH,$csvDelimiter,$colnameDelimiter,\@header);
}

#print Dumper($compare);

# start of main loop - process tables
#TABLE: while ( my $tableName = $compare->getTable() ) {
while ( my $tableName = $compare->getTable() ) {

	#warn "Table: $tableName\n";

	$compare->processTabIdx (
		TABLE => $tableName,
		DEBUG => $debug,
		RPTARY => \@rptOut,
		RATIO	=> $idxRatioAlertThreshold,
		DIRS => \%dirs,
		CSVHASH => \%csvIndexes
	);

}

closeSession($dbh);

# create the csv file
if ( $csvOut ) {
	foreach my $tabIdx ( sort keys %csvIndexes ) {
		# workaround for a bug I was tracking down
		# fixed the bug, but no need to remove this trap
		if ( $#{$csvIndexes{$tabIdx}} < 0 ) {
			print "csvPrint Call - null array tabIdx: $tabIdx\n";
			next;
		}
		csvPrint($csvFH,$csvDelimiter,$colnameDelimiter,$csvIndexes{$tabIdx});
	}
}

if ($debug) {
	push @rptOut, 'csvIndexes: ';
	foreach my $line ( Dumper(\%csvIndexes)) { push @rptOut, $line }
	# not sure why this was done
	#push @rptOut, '@rptOut: ';
	#foreach my $line ( Dumper(\@rptOut) ) { push @rptOut, $line }
}

# print the log
foreach my $line (@rptOut) { print $line }

# end of main

sub usage {

	my $exitVal = shift;
	use File::Basename;
	my $basename = basename($0);
	print qq{
$basename

usage: $basename - analyze schema indexes for redundancy

   $basename --database --username --password 

  --database do not specify for local SYSDBA connection (ORACLE_SID must be set)
  --username do not specify for local SYSDBA connection
  --password specifies that user will be asked for password
             this option does NOT accept a password

  --idxChkTable fully qualified name of table that contains used index names
                defaults to 'avail.used_ct_indexes'

  --index-ratio-alert-threshold 
					 the threshold at which to report on 2 indexes having the same leading columns
					 default is 75 - if 75% of the leading columns of the index with the least number 
					 of columns are the same as the other column, provide extra reporting.

  --schema    Examine indexes for this schema(s) - defaults to '%' which is all schemas other than SYS and SYSTEM
              SQL wildcards can be used

  --gen-column-groups generate column group DDL - default is enabled
                      disable with --no-gen-column-groups

  --gen-index-ddl     generate index DDL - default is enabled
                      disable with --no-gen-index-ddl

  --gen-ddl           generate both column group and index DDL - default is enabled
                      the only value for this option is to use --no-gen-ddl to disable both

  --sysdba            connect as sysdba - do not specify database or username

  --csv-file          File name for CSV output.  There will be no CSV output unless the file is named
  --csv-delimiter     Delimiter to separate fields in CSV output - defaults to ,
  --column-delimiter  Delimiter to separate column names in CSV field for index column names - defaults to |

	examples here:

		$basename  --database orcl --password --sysdba
		$basename  --sysdba

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









