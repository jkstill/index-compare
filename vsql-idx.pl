
# template for DBI programs

use warnings;
use FileHandle;
use DBI;
use strict;

use Getopt::Long;

my %optctl = ();

my $dbh = DBI->connect(
	'dbi:Oracle:' ,
	undef, undef,
	{
		RaiseError => 1,
		AutoCommit => 0,
		ora_session_mode => 2
	}
	);

die "Connect to  oracle failed \n" unless $dbh;

my  $lastTimeStampFile='./last-timestamp.txt';
my  $lastTimeStamp = '2017-01-01 00:00:00';

if ( -r $lastTimeStampFile ) {
	open TS,'<',$lastTimeStampFile || die " cannot open $lastTimeStampFile - $!\n";
	my @timestamps=<TS>;
	close TS;
	$lastTimeStamp = $timestamps[$#timestamps];
		
}

my $outputFile = 'vsql-idx.csv';
if ( ! -r $outputFile ) {
	open OF,'>',$outputFile || die " cannot open $outputFile - $!\n";
	print OF join(',',qw[timestamp sql_id plan_hash_value inst_id object_name objectnum]), "\n";
	close OF;
}

print "Timestamp: $lastTimeStamp\n";

# apparently not a database handle attribute
# but IS a prepare handle attribute
#$dbh->{ora_check_sql} = 0;
$dbh->{RowCacheSize} = 100;

my $sql=q{ select
	to_char(timestamp,'yyyy-mm-dd hh24:mi:ss') timestamp
	, sql_id
	, plan_hash_value
	, inst_id
	--, object_owner
	, object_name
	, object#
	-- no partitions in CT schema
	--, partition_start
	--, partition_stop
	--, partition_id
from gv$sql_plan
where object_owner = 'CT'
	and object_type = 'INDEX'
	and timestamp > to_date(?,'yyyy-mm-dd hh24:mi:ss')
order by 1,2,3};

open OF,'>>',$outputFile || die " cannot open $outputFile - $!\n";

my $sth = $dbh->prepare($sql,{ora_check_sql => 0});

$sth->execute($lastTimeStamp);

my $rowCount=0;
while( my $ary = $sth->fetchrow_arrayref ) {
	$rowCount++;
	my ($timeStamp,$sqlID,$planHashValue,$instanceID,$objectName,$objectNum) = @{$ary};
	print OF join(',',@{$ary}),"\n";
	$lastTimeStamp = $timeStamp;
}

open TS,'>',$lastTimeStampFile || die " cannot open $lastTimeStampFile for write - $!\n";

print "Rows added: $rowCount\n";

print TS "$lastTimeStamp";

$dbh->disconnect;

sub usage {
	my $exitVal = shift;
	$exitVal = 0 unless defined $exitVal;
	use File::Basename;
	my $basename = basename($0);
	print qq/

usage: $basename

  -database		  target instance
  -username		  target instance account name
  -password		  target instance account password
  -sysdba		  logon as sysdba
  -sysoper		  logon as sysoper

  example:

  $basename -database dv07 -username scott -password tiger -sysdba
/;
	exit $exitVal;
};

