
# template for DBI programs

use warnings;
use FileHandle;
use DBI;
use strict;
use Getopt::Long;
use Data::Dumper;

# prototypes
sub insertSQLText ($$$);
sub insertPlanText ($$$$);


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
$dbh->{LongReadLen} = 2*1024*1024;

my $insertIndexSQL=qq{insert into ${schemaName}.used_ct_indexes(owner,index_name) values(?,?)};

my $sth = $dbh->prepare($insertIndexSQL,{ora_check_sql => 0});

# operation from STDIN
# input is the name of an index in the CT schema.
# get the index names this way:
#    cut -f5 -d, vsql-idx.csv| sort -u 
#
#  run as many times as needed

while (<>) {

	chomp;
	my $line = uc($_);
	# should already be upper case, but...
	my ($sqlId,$planHashValue,$owner,$indexName) = split(/,/,$line);
	$sqlId=lc($sqlId);

print qq{

owner: $owner
index: $indexName

};
	
	eval {
		local $SIG{__WARN__} = sub { }; # do not want to see ORA-0001 errors
   		local $dbh->{PrintError} = 0;
   		local $dbh->{RaiseError} = 1;

		$sth->execute($owner, $indexName);
	};


	if ($@) {
		my($err,$errStr) = ($dbh->err, $dbh->errstr);
		if ($err == 1) { # dup_val_on_index
			# already have this index in the table
			print "skipping $indexName\n";
			next;
		} else {
			$dbh->rollback;
			$dbh->disconnect;
			die qq{query died - $err - $errStr\n};
		}
	} else  {
		print "adding $indexName\n";
		# get the SQL text

		my $insertSqlResult = insertSQLText($dbh,$username,$sqlId);
		
		# get the plan (basic plan only)
		my $insertPlanResult = insertPlanText($dbh,$username,$sqlId,$planHashValue);
	}

}

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
  --sysdba		logon as sysdba - do not specify database or username

  example:

  $basename --database dv07 --username scott --password --sysdba
  $basename --sysdba
/;
	exit $exitVal;
};



sub insertSQLText ($$$) {

	my ($dbh,$schema,$sqlId) = @_;

#print qq{

	#schema: $schema
	#sql_id: $sqlId

#};

	my $awrSQL=q{select sql_text from dba_hist_sqltext where sql_id = ?};
	my $awrSth=$dbh->prepare($awrSQL);
	my $insertSQL=qq{insert into ${schema}.used_ct_index_sql (sql_id,sql_text) values(?,?) };
	my $existsSQL=qq{select count(*) sql_count from ${schema}.used_ct_index_sql where sql_id = ?};

	my $existsSth=$dbh->prepare($existsSQL);
	$existsSth->execute($sqlId);
	my ($sqlFound) = $existsSth->fetchrow_array;
	return $sqlFound if $sqlFound;  # no need to continue

	# first look in gv$sql

	my $gvSQL=q{select
replace(translate(sql_fulltext,'0123456789','999999999'),'9','') SQL_FULLTEXT
from gv$sql
where sql_id = ?
group by replace(translate(sql_fulltext,'0123456789','999999999'),'9','') };
	my $gvSth=$dbh->prepare($gvSQL);
	$gvSth->execute($sqlId);
	my ($SQL)=$gvSth->fetchrow_array;

	$sqlFound = $SQL ? 1 : 0;
	
	# then look in dba_hist_sqltext
	if (! $sqlFound ) {
		$awrSth->execute($sqlId);
		($SQL)=$awrSth->fetchrow_array;
		$sqlFound = $SQL ? 1 : 0;
	}

	# return failure
	return $sqlFound unless $sqlFound;

	# this statement should not fail as we already checked previous for this SQL_ID
	my $insertSth=$dbh->prepare($insertSQL);
	$insertSth->execute($sqlId,$SQL);

	$sqlFound;

}


sub insertPlanText ($$$$) {

	my ($dbh,$schema,$sqlId,$planHashValue) = @_;

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
	return $planFound if $planFound;  # no need to continue

	# first look in gv$sql_plan

	my $gvSth=$dbh->prepare($gvSQL);
	$gvSth->execute($planHashValue,$sqlId);
	my @planText=();
	while (my $ary = $gvSth->fetchrow_arrayref ) {
		push @planText,$ary->[0];
	}

	$planFound = $#planText >= 0 ? 1 : 0;
	
	# then look in dba_hist_sqltext
	if (! $planFound ) {
		$awrSth->execute($planHashValue,$sqlId);
		while (my $ary = $awrSth->fetchrow_arrayref ) {
			push @planText,$ary->[0];
		}
		$planFound = $#planText >= 0 ? 1 : 0;
	}

	# return failure
	return $planFound unless $planFound;

	# this statement should not fail as we already checked previous for this SQL_ID
	my $insertSth=$dbh->prepare($insertPlanSQL);
	$insertSth->execute($planHashValue,join("\n",@planText));

	$planFound;
	
}
















