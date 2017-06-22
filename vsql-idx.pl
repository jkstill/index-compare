
# template for DBI programs

use warnings;
use FileHandle;
use DBI;
use strict;

use Getopt::Long;

use lib './lib';
use Generic qw(getPassword);


my $db=''; # left as blank for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=0;
my $password='';
my $username='';
my $sysdba=0;
my $help=0;
my $debug=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"sysdba!" => \$sysdba,
		"debug!" => \$debug,
		"password!" => \$getPassword,
		"h|help!" => \$help
) or die usage(1);

usage() if $help;

$sysdba=2 if $sysdba;

if ($getPassword) {
	$password = getPassword();
	#print "Password: $password\n";
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
	print OF join(',',qw[timestamp sql_id plan_hash_value inst_id object_owner object_name objectnum]), "\n";
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
	, object_owner
	, object_name
	, object#
	-- partitions not important for this
	--, partition_start
	--, partition_stop
	--, partition_id
from gv$sql_plan
where object_owner in (
	select username
	from dba_users
	where default_tablespace not in ('SYSTEM','SYSAUX')
)
	and object_type = 'INDEX'
	and timestamp > to_date(?,'yyyy-mm-dd hh24:mi:ss')
order by 1,2,3};

open OF,'>>',$outputFile || die " cannot open $outputFile - $!\n";

my $sth = $dbh->prepare($sql,{ora_check_sql => 0});

$sth->execute($lastTimeStamp);

my $rowCount=0;
while( my $ary = $sth->fetchrow_arrayref ) {
	$rowCount++;
	my ($timeStamp,$sqlID,$planHashValue,$instanceID,$objectOwner,$objectName,$objectNum) = @{$ary};
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

  --database  target instance
  --username  target instance account name
  --password  prompt for password 
  --sysdba    logon as sysdba

  example:

  $basename -database dv07 -username scott -password  -sysdba
/;
	exit $exitVal;
};



