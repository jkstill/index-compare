
# listagg-workaround.pl
# workaround for lack of listagg() function in Oracle 10g

use warnings;
use FileHandle;
use DBI;
use strict;
use Getopt::Long;

sub getColumnList($$$); # dbh, owner, index name

my $db=undef; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $password=undef;
my $username=undef;
my $sysdba=0;
my $schemaName = 'AVAIL';
my $help=0;
my $debug=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"schema=s" => \$schemaName,
		"sysdba!" => \$sysdba,
		"debug!" => \$debug,
		"password=s" => \$password,
		"h|help!" => \$help
) or die usage(1);

usage() if $help;

$sysdba=2 if $sysdba;
$schemaName = uc($schemaName);

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


# apparently not a database handle attribute
# but IS a prepare handle attribute
#$dbh->{ora_check_sql} = 0;
$dbh->{RowCacheSize} = 100;

my $idxSql=qq{select table_name, index_name, index_type
from dba_indexes
where owner = ?
	and index_type in ('NORMAL/REV','FUNCTION-BASED NORMAL','NORMAL')};

my $idxSth = $dbh->prepare($idxSql,{ora_check_sql => 0});

# operation from STDIN
# input is the name of an index in the CT schema.
# get the index names this way:
#    cut -f5 -d, vsql-idx.csv| sort -u 
#
#  run as many times as needed
#
$idxSth->execute($schemaName);

while (my $ary = $idxSth->fetchrow_arrayref ) {

	my ($tableName, $indexName, $indexType) = @{$ary};

	print "Table: $tableName  Index: $indexName  Type: $indexType\n";
	my $colList = getColumnList($dbh,$schemaName,$indexName);
	print "\t Columns: $colList\n";

}

$dbh->disconnect;

sub usage {
	my $exitVal = shift;
	$exitVal = 0 unless defined $exitVal;
	use File::Basename;
	my $basename = basename($0);
	print qq/

usage: $basename

  --database   target instance
  --username   target instance account name
  --password   password
  --schema     schema where used_ct_indexes table is located
  --sysdba		logon as sysdba

  example:

  $basename -database dv07 -username scott -password -sysdba
/;
	exit $exitVal;
};

sub getColumnList($$$) {
	my ($dbh, $owner,$indexName) = @_;

	my $sql = 'select column_name from dba_ind_columns where index_owner = ? and index_name = ? order by column_position';
	my $sth = $dbh->prepare($sql,{ora_check_sql => 0});
	$sth->execute($owner,$indexName);

	my $colList='';
	while (my $ary = $sth->fetchrow_arrayref ) {
		$colList .= $ary->[0] . ',';	
	}
	chop $colList; # remove trailing comma

	return $colList;
}















