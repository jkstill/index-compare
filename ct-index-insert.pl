
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

# apparently not a database handle attribute
# but IS a prepare handle attribute
#$dbh->{ora_check_sql} = 0;
$dbh->{RowCacheSize} = 100;

my $sql=q{insert into avail.used_ct_indexes(index_name) values(?)};

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

