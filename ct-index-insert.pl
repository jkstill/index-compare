
# template for DBI programs

use warnings;
use FileHandle;
use DBI;
use strict;
use Getopt::Long;


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

my $sql=qq{insert into ${schemaName}.used_ct_indexes(index_name) values(?)};

my $sth = $dbh->prepare($sql,{ora_check_sql => 0});

# operation from STDIN
# input is the name of an index in the CT schema.
# get the index names this way:
#    cut -f5 -d, vsql-idx.csv| sort -u 
#
#  run as many times as needed

while (<>) {

	chomp;
	# should already be upper case, but...
	my $indexName = uc($_);
	
	eval {
		local $SIG{__WARN__} = sub { }; # do not want to see ORA-0001 errors
   		local $dbh->{PrintError} = 0;
   		local $dbh->{RaiseError} = 1;

		$sth->execute($indexName);
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
	}

	print "adding $indexName\n";


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
  --sysdba		logon as sysdba

  example:

  $basename -database dv07 -username scott -password -sysdba
/;
	exit $exitVal;
};


