
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
sub getScanSTH ($$);
sub insertIdxInfo ($$$$);
sub insertSQLText ($$$$$$);
sub insertPlanText ($$$$$);
sub insertSqlPlanPair($$$$$$);
sub sqlTokenizer($);


my $db=undef; # left as undef for local sysdba connection
# the --password option will not accept a password
# but just indicates whether a password will be necessary
# if required, the password will be requested
my $getPassword=undef;
my $password=undef;
my $username=undef;
my $sysdba=undef;
my $sessionMode=0;
my $schemaName = 'AVAIL';
my $help=0;
my $debug=0;
my $useAWR=0;

GetOptions (
		"database=s" => \$db,
		"username=s" => \$username,
		"schema=s" => \$schemaName,
		"use-awr!" => \$useAWR,
		"debug!" => \$debug,
		"sysdba!" => \$sysdba,
		"password!" => \$getPassword,
		"h|help!" => \$help
) or die usage(1);

usage() if $help;


$sessionMode=ORA_SYSDBA if $sysdba;
$schemaName = uc($schemaName);

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

my  $lastTimeStampFile='./last-timestamp.txt';
my  $lastTimeStamp = '2017-01-01 00:00:00';

if ( -r $lastTimeStampFile ) {
	open TS,'<',$lastTimeStampFile || die " cannot open $lastTimeStampFile - $!\n";
	my @timestamps=<TS>;
	close TS;
	$lastTimeStamp = $timestamps[$#timestamps];
		
}

# this file no longer required, just acts as a log
my $outputFile = 'csv/vsql-idx.csv';
if ( ! -r $outputFile ) {
	open OF,'>',$outputFile || die " cannot open $outputFile - $!\n";
	print OF join(',',qw[timestamp sql_id child_number plan_hash_value inst_id object_owner object_name objectnum]), "\n";
	close OF;
}

print "Timestamp: $lastTimeStamp\n";
open OF,'>>',$outputFile || die " cannot open $outputFile - $!\n";

my $scanSTH = getScanSTH($dbh,$lastTimeStamp);

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

my $xactCounter=0;
my $commitFrequency=1000;

my $recordCount=0;
while( my $ary = $scanSTH->fetchrow_arrayref ) {
 	my ($timeStamp,$sqlID,$childNumber,$planHashValue,$instanceID,$objectOwner,$objectName,$objectNum,$exactMatchSig,$forceMatchSig) = @{$ary};

	print qq{

######## MAIN LOOP ###############

   timestamp: $timeStamp
      SQL_ID: $sqlID
   plan hash: $planHashValue
    instance: $instanceID
       owner: $objectOwner
  index name: $objectName
  obj number: $objectNum

} if $debug;

	my $idxResult = insertIdxInfo($dbh,$schemaName,$objectOwner,$objectName);
	if ($idxResult) {
		# write to file only if added to table (new index)
		$recordCount++;
		print OF join(',',@{$ary}[0..7]),"\n";
	}

	$lastTimeStamp = $timeStamp;

	# get the SQL text
	my $insertSqlResult = insertSQLText($dbh,$schemaName,$sqlID,$useAWR,$exactMatchSig,$forceMatchSig);
	
	# get the plan (basic plan only)
	my $insertPlanResult = insertPlanText($dbh,$schemaName,$sqlID,$planHashValue,$useAWR);

	if ($debug) {
			printf "SQL_ID: $sqlID - plan was ";
		if ($insertPlanResult) {
			print "Found!\n";
		} else {
			print "NOT Found\n";
		}
	}

	# insert the plan pairs
	if ($insertPlanResult and $insertSqlResult) {
		my $insertPlanSqlPairResult = insertSqlPlanPair($dbh,$schemaName,$objectOwner,$objectName,$planHashValue,$sqlID);
	}

	# avoid stressing out undo unnecessarily
	$dbh->commit unless $xactCounter++ % $commitFrequency;

}

open TS,'>',$lastTimeStampFile || die " cannot open $lastTimeStampFile for write - $!\n";

print "New index records added: $recordCount\n";

print TS "$lastTimeStamp";

$dbh->commit;
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
  --schema     schema where used_ct_indexes table is located
  --use-awr    allow looking for plans and SQL text in AWR (normally should not be necessary)
  --sysdba		logon as sysdba - do not specify database or username

  example:

  $basename --database dv07 --username scott --password --sysdba
  $basename --sysdba
/;
	exit $exitVal;
};



sub insertSQLText ($$$$$$) {

	my ($dbh,$schema,$sqlId,$useAWR,$exactMatchSig,$forceMatchSig) = @_;

#print qq{

	#schema: $schema
	#sql_id: $sqlId

#};

	my $awrSQL=q{select sql_text from dba_hist_sqltext where sql_id = ?};
	my $awrSth=$dbh->prepare($awrSQL);
	my $insertSQL=qq{insert into ${schema}.used_ct_index_sql (sql_id,sql_text, exact_matching_signature, force_matching_signature) values(?,?,?,?) };
	my $existsSQL=qq{select count(*) sql_count from ${schema}.used_ct_index_sql where sql_id = ?};

	my $existsSth=$dbh->prepare($existsSQL);
	$existsSth->execute($sqlId);
	my ($sqlFound) = $existsSth->fetchrow_array;
	return $sqlFound if $sqlFound;  # no need to continue

	# first look in gv$sql

	# this SQL is a workaround due to issues with sql_fulltext in some versions of oracle
	# How to get full sql text statement from v$sql (Doc ID 437304.1)
	# the dbms_lob.substr() was added due to sql text over 4k
	# so now we are back where we started.
	
	my $gvSQL=q{select
replace(translate(dbms_lob.substr(sql_fulltext,4000),'0123456789','999999999'),'9','') SQL_FULLTEXT
from gv$sql
where sql_id = ?
group by replace(translate(dbms_lob.substr(sql_fulltext,4000),'0123456789','999999999'),'9','') };
	my $gvSth=$dbh->prepare($gvSQL);
	$gvSth->execute($sqlId);
	my ($SQL)=$gvSth->fetchrow_array;

	$sqlFound = $SQL ? 1 : 0;
	
	# then look in dba_hist_sqltext
	if (! $sqlFound && $useAWR ) {
		$awrSth->execute($sqlId);
		($SQL)=$awrSth->fetchrow_array;
		$sqlFound = $SQL ? 1 : 0;
	}

	# return failure
	return $sqlFound unless $sqlFound;

	# this statement should not fail as we already checked previous for this SQL_ID
	my $insertSth=$dbh->prepare($insertSQL);
	$insertSth->execute($sqlId,$SQL,$exactMatchSig,$forceMatchSig);

	$sqlFound;

}


# return true if plan inserted or already exists
# return false otherwise

sub insertPlanText ($$$$$) {

	my ($dbh,$schema,$sqlId,$planHashValue,$useAWR) = @_;

	# sqlid used used just to simplify plan lookup
	# not storing any execution metrics here

	my $awrSQL=q{with plandata as (
	select id, lpad(' ',depth,' ') || operation operation, object_name
	from dba_hist_sql_plan
	where plan_hash_value = ?
	and sql_id = ?
	order by id
)
select lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name plan_line
from plandata
group by lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name
order by 1};


	my $gvSQL=q{with plandata as (
	select id, lpad(' ',depth,' ') || operation operation, object_name
	from gv$sql_plan
	where plan_hash_value = ?
	and sql_id = ?
	order by id
)
select lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name plan_line
from plandata
group by lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name
order by 1};

	my $awrSth=$dbh->prepare($awrSQL);
	my $insertPlanSQL=qq{insert into ${schema}.used_ct_index_plans (plan_hash_value,plan_text) values(?,?) };
	my $existsSQL=qq{select count(*) plan_count from ${schema}.used_ct_index_plans where plan_hash_value = ?};

	my $existsSth=$dbh->prepare($existsSQL);
	$existsSth->execute($planHashValue);
	my ($planFound) = $existsSth->fetchrow_array;

	print "PlanFound: $planFound\n" if $debug;

	return $planFound if $planFound;  # no need to continue

	# first look in gv$sql_plan

	print qq{

===========================
gv\$sql_plan check:

SQL_ID: $sqlId
HASH  : $planHashValue

} if $debug;

	my $gvSth=$dbh->prepare($gvSQL);
	$gvSth->execute($planHashValue,$sqlId);
	my @planText=();
	while (my $ary = $gvSth->fetchrow_arrayref ) {
		push @planText,$ary->[0];
	}

	$planFound = $#planText >= 0 ? 1 : 0;
	print "GV\$SQL Plan Found: $planFound\n" if $debug;
	
	# then look in dba_hist_sqltext
	if (! $planFound && $useAWR ) {
		$awrSth->execute($planHashValue,$sqlId);
		while (my $ary = $awrSth->fetchrow_arrayref ) {
			push @planText,$ary->[0];
		}
		$planFound = $#planText >= 0 ? 1 : 0;
		print "AWR Plan Found: $planFound\n" if $debug;
	}

	print 'Plan Text: ', Dumper(\@planText) if $debug;

	# return failure
	return $planFound unless $planFound;


	# this statement should not fail as we already checked previous for this SQL_ID
	my $insertSth=$dbh->prepare($insertPlanSQL);
	$insertSth->execute($planHashValue,join("\n",@planText));

	$planFound;
	
}

sub insertSqlPlanPair($$$$$$) {

	my ($dbh,$schema,$owner,$indexName,$planHashValue,$sqlId) = @_;

	my $insertSql = qq{insert into ${schema}.used_ct_index_sql_plan_pairs (owner, index_name, plan_hash_value, sql_id) values(?,?,?,?)};

	# primary key (owner,index_name,plan_hash_value,sql_id)
	#
	my $existsSql = qq{select count(*) pair_count from ${schema}.used_ct_index_sql_plan_pairs 
where owner = ?
	and index_name = ?
	and plan_hash_value = ?
	and sql_id = ?};

	my $existsSth=$dbh->prepare($existsSql);
	$existsSth->execute($owner,$indexName,$planHashValue,$sqlId);

	my ($pairFound) = $existsSth->fetchrow_array;

	return $pairFound if $pairFound;

	my $insertSth = $dbh->prepare($insertSql);
	$insertSth->execute($owner,$indexName,$planHashValue,$sqlId);

	1;

}

=head1 insertIdxInfo

 Insert index info into app table

 Returns 1 if index inserted successfully.
 Returns 0 if index already saved
 Dies on failure

 example:

 my $idxInsertResult = insertIdxInfo($dbh,'SCOTT','SH','SOME_INDEX');

 if ($idxInsertResult) {
 	log('Index Inserted');
 } else {
   log('Index Exists');
 }

=cut


sub insertIdxInfo($$$$) {

	my ($dbh,$schema,$owner,$indexName) = @_;

	my $insertIndexSQL=qq{insert into ${schemaName}.used_ct_indexes(owner,index_name) values(?,?)};
	my $sth = $dbh->prepare($insertIndexSQL,{ora_check_sql => 0});

	# primary key (owner,index_name,plan_hash_value,sql_id)
	#
	my $existsSql = qq{select count(*) idx_count from ${schema}.used_ct_indexes 
where owner = ?
	and index_name = ?};

	my $existsSth=$dbh->prepare($existsSql);
	$existsSth->execute($owner,$indexName);

	my ($idxFound) = $existsSth->fetchrow_array;

	return 0 if $idxFound;

	my $insertSth = $dbh->prepare($insertIndexSQL);
	$insertSth->execute($owner,$indexName);

	1;

}


sub getScanSTH ($$) {
	my ($dbh,$timestamp) = @_;
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
   	--where default_tablespace not in ('SYSTEM','SYSAUX')
		where gs.force_matching_signature != 0
			and gsp.object_owner not in ('SYS','SYSMAN')
	)
   	and object_type = 'INDEX'
		and timestamp > to_date(?,'yyyy-mm-dd hh24:mi:ss')
	order by 1,2,3};

	my $scanSTH = $dbh->prepare($scanSQL,{ora_check_sql => 0});
	$scanSTH->execute($lastTimeStamp);
	$scanSTH;

}

=head1 sqlTokenizer

 Get an MD5 Hash to complement the force matching columns
 used for SQL that contains both literals and bind variables
 
 returns an MD5 Hex Value

=cut


sub sqlTokenizer($) {
	my $sql = shift;

	my $tokenizer = String::Tokenizer->new();
	$tokenizer->tokenize($sql);
	my @sql = $tokenizer->getTokens();

	# remove content in single quotes
	s/(').*(')/$1$2/ for @sql;

	$sql = join(' ',@sql);
	return md5_hex($sql);
}


