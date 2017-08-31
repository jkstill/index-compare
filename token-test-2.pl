# template for DBI programs

use warnings;
use FileHandle;
use DBI;
use DBD::Oracle qw(:ora_session_modes);
use strict;
use Getopt::Long;
use Data::Dumper;
use Digest::MD5 qw(md5_hex);

use lib './lib';
use Generic qw(getPassword);
use String::Tokenizer;

# prototypes
sub getScanSTH ($);
sub insertIdxInfo ($$$$);
sub insertSQLText ($$$$$$);
sub insertPlanText ($$$$$);
sub insertSqlPlanPair($$$$$$);
sub sqlMD5Hash($);
sub getSqlText($$$);

$|++;

my $db=undef; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=undef;
my $password=undef;
my $username=undef;
my $sysdba=undef;
my $sessionMode=0;
my $help=0;
my $debug=0;
my $useAWR=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"use-awr!" => \$useAWR,
		"debug!" => \$debug,
		"sysdba!" => \$sysdba,
		"password!" => \$getPassword,
		"h|help!" => \$help
) or die usage(1);

usage() if $help;


$sessionMode=ORA_SYSDBA if $sysdba;

if ($getPassword) {
	$password = getPassword();
	#print "Password: $password\n";
}
			#

my $dbh = DBI->connect(
	"dbi:Oracle:${db}" , 
	$username,$password,
	#$username, $password,
	{
		RaiseError => 1,
		AutoCommit => 0,
		ora_session_mode => $sessionMode
	}
);

die "Connect to  oracle failed \n" unless $dbh;

# apparently not a database handle attribute
# but IS a prepare handle attribute
#$dbh->{ora_check_sql} = 0;
$dbh->{RowCacheSize} = 100;
# 64k for SQL statements is enough!
$dbh->{LongReadLen} = 64*1024;

my $scanSTH = getScanSTH($dbh);

=head1 Program Flow

 Scan gv$sql_plan for rows with a timestamp GT than the value found in last-timestamp.txt.

 while DATA:
   Look up the SQL_ID in the app tables.  
	if not found:
	  save index data
	  save sql_text (if available)
	  save execution_plan (if available)
	else
	  if not sql_text already saved:
	    save sql_text (if available)
	  end if
	  if not execution_plan already saved:
	    save execution_plan (if available)
	  end if
	end if
 
=cut

while( my $ary = $scanSTH->fetchrow_arrayref ) {
 	my ($timeStamp,$sqlID,$childNumber,$planHashValue,$instanceID,$objectOwner,$objectName,$objectNum,$exactMatchSig,$forceMatchSig) = @{$ary};

	my $sqlText = getSqlText($dbh,$sqlID,$instanceID);

	print "######## MAIN LOOP ###############:\n" if $debug;

	print "SQL: $sqlText\n\n" if $debug;

	my $md5Hex='';

	# see FORCE-MATCHING-TRUTH-TABLE.txt
	if ( 
		$forceMatchSig == $exactMatchSig 
			and
		$sqlText =~ /:.[[:alpha:]]/
			and 
		$sqlText =~ /\'.*\'/
		# this does not work - not sure why, have used positive lookahead before
		#$sqlText =~ /(?=\'.*\')(?=:.*)/
	)
	{
		$md5Hex = sqlMD5Hash($sqlText);
	}

	print qq{


   timestamp: $timeStamp
      SQL_ID: $sqlID
   plan hash: $planHashValue
    instance: $instanceID
       owner: $objectOwner
  index name: $objectName
  obj number: $objectNum
   exact Sig: $exactMatchSig
   force Sig: $forceMatchSig
         MD5: $md5Hex

} if $debug;


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
  --password   prompt for password
  --use-awr    allow looking for plans and SQL text in AWR (normally should not be necessary)
  --sysdba		logon as sysdba - do not specify database or username

  example:

  $basename --database dv07 --username scott --password --sysdba
  $basename --sysdba
/;
	exit $exitVal;
};



sub getScanSTH ($) {
	my ($dbh) = @_;
	my $scanSQL=q{select distinct
   	to_char(max(gsp.timestamp) over (partition by gs.sql_id),'yyyy-mm-dd hh24:mi:ss') timestamp
   	, gsp.sql_id
		, min(gs.child_number) over (partition by gs.sql_id) child_number
   	, gsp.plan_hash_value
   	, gsp.inst_id
   	, gsp.object_owner
   	, gsp.object_name
   	, gsp.object#
		, gs.exact_matching_signature
		, gs.force_matching_signature
   	-- partitions not important for this
   	--, partition_start
   	--, partition_stop
   	--, partition_id
	from gv$sql_plan gsp
	join gv$sql gs on gs.sql_id = gsp.sql_id
		and gs.inst_id = gsp.inst_id
		and gs.plan_hash_value = gsp.plan_hash_value
	where gsp.object_owner in (
   	select username
   	from dba_users
		where gs.force_matching_signature != 0
	)
   	--and object_type = 'INDEX'
		--and gs.sql_id in ('1j8hs77mzf3jd','576vc50wnqhd6') -- from force-match-tests.log
	order by 1,2,3};

	my $scanSTH = $dbh->prepare($scanSQL,{ora_check_sql => 0});
	$scanSTH->execute;
	$scanSTH;

}

sub getSqlText($$$) {

	my ($dbh,$sqlID,$instanceID) = @_;
	my $sql = q{select sql_fulltext from gv$sqlstats where sql_id = ? and inst_id = ?};

	my $sth = $dbh->prepare($sql);
	$sth->execute($sqlID,$instanceID);
	my ($sqlText) = $sth->fetchrow_array;
	$sth->finish;
	return $sqlText;
}

sub sqlMD5Hash($) {
	my $sql = shift;

	my $tokenizer = String::Tokenizer->new();
	$tokenizer->tokenize($sql);
	my @sql = $tokenizer->getTokens();

	# remove content in single quotes
	s/(').*(')/$1$2/ for @sql;

	$sql = join(' ',@sql);
	return md5_hex($sql);
}


