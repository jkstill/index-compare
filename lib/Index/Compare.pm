
package Index::Compare;

use strict;
use warnings;

use Carp;
use Data::Dumper;

sub getIdxPairInfo($);

my $tabSql = q{select
table_name
from dba_tables
where owner = ?
	and table_name not like 'DR$%$I%' -- Text Indexes
order by table_name
};

my $idxInfoSql = q{with cons_idx as (
   select /*+ no_merge */
      table_name, index_name , constraint_name, constraint_type
   from dba_constraints
   where owner = ?
   and constraint_type in ('R','U','P')
   and index_name is not null
), 
-- going to assume all tablespaces are db_block_size
block_size as (
	select value block_size from v$parameter where name = 'db_block_size'
)
select i.table_name, i.index_name
   , i.leaf_blocks * bs.block_size bytes
   , nvl(idx.constraint_name , 'NONE') constraint_name
   , nvl(idx.constraint_type , 'NONE') constraint_type
from dba_indexes i
natural join block_size bs
left outer join cons_idx idx on idx.table_name = i.table_name
   and idx.index_name = i.index_name
where i.owner = ?
	and i.index_name = ?
};

# indexes ordered so that those support unique and primary constraints are considered last
my $colSql = q{with cons_idx as (
   select /*+ no_merge no_push_pred */
      table_name, index_name , constraint_name, constraint_type
   from dba_constraints
   where owner = ?
		and table_name = ?
   	and constraint_type in ('R','U','P')
   	and index_name is not null
), 
idxinfo as (
	select /*+ no_merge no_push_pred */
		ic.index_name
		, nvl(cons.constraint_type , 'NONE') constraint_type
		, listagg(ic.column_name,',') within group (order by ic.column_position) column_list
	from dba_ind_columns ic
	join dba_indexes i on i.owner = ic.index_owner
		and i.index_name = ic.index_name
		and i.index_type in ('NORMAL')
	left outer join cons_idx cons on cons.table_name = i.table_name
   	and cons.index_name = i.index_name
	where ic.index_owner = ?
		and ic.table_owner = ?
		and ic.table_name = ?
	group by ic.index_name, nvl(cons.constraint_type , 'NONE') 
)
select
	index_name
	, column_list
from idxinfo 
order by 
	case 
		when constraint_type = 'NONE' then 1
		when constraint_type = 'R' then 2
		when constraint_type = 'U' then 3
		when constraint_type = 'P' then 5
		else 4
	end 
};



sub new {
	my $pkg = shift;
	my $class = ref($pkg) || $pkg;

	my (%args) = @_;
	my $dbh = $args{DBH};

	croak "Attribute SCHEMA is required in $class::new\n" unless $args{SCHEMA};

	$args{IDX_CHK_TABLE} = 'avail.used_ct_indexes' unless defined($args{IDX_CHK_TABLE});
	$args{RATIO} = 75 unless defined($args{RATIO});
	#
	# SQL to check the table of known used indexes
	$args{IDX_CHK_SQL} =  qq{select index_name
from $args{IDX_CHK_TABLE}
where index_name = ?};

	croak "Attribute DBH is required in $class::new\n" unless $args{DBH};

	return bless \%args, $class;
}

{

	my @tables=();
	my $el=-1;
	my $maxEl=undef;

	sub getTable {
		my $self = shift;
		my $dbh = $self->{DBH};
	
		if ( ! @tables ) {
			my $tabSth = $dbh->prepare($tabSql,{ora_check_sql => 0});
			$tabSth->execute($self->{SCHEMA});
			while ( my $table = $tabSth->fetchrow_arrayref) { 
				#print "Table: $table->[0]\n";
				push @tables, $table->[0];
			};
			$maxEl = $#tables;
		}

		$el++;
		return ( $el <= $maxEl ) ? $tables[$el] : undef;

	}

}

sub getIdxColInfo {
	my $self = shift;
	my (%args) = @_;
	my $dbh = $self->{DBH};

	my $indexes = $args{IDXARY};
	my $colData = $args{COLHASH};

	#print "col Args: " , Dumper(\%args);
	#print "self->getIdxColInfo: ", Dumper($self);

	#print qq{

	#getIdxColInfo:
	
	#SCHEMA: $self->{SCHEMA}
	#TABLE: $args{TABLE}

#};
	#
	print "Getting column Info\n";

	my $colSth = $dbh->prepare($colSql,{ora_check_sql => 0});
	$colSth->execute($self->{SCHEMA}, $args{TABLE}, $self->{SCHEMA}, $self->{SCHEMA}, $args{TABLE});
	
	while ( my $colAry = $colSth->fetchrow_arrayref) { 
		my ($indexName,$columnList) = @{$colAry};

		print "Cols:  $columnList\n";

		push @{$indexes}, $indexName;
		push @{$colData->{$indexName}},split(/,/,$columnList);

	}
}

# check the usage table to see if the index is known to be used.
sub isIdxUsed {
	my $self = shift;
	my $idxName = shift;
	my $dbh = $self->{DBH};

	my $sth = $dbh->prepare($self->{IDX_CHK_SQL},{ora_check_sql => 0});
	$sth->execute($idxName);

	my $result = $sth->fetchrow_arrayref;
	$sth->finish;

	#if ( defined($sth->fetchrow_arrayref)) { return 1 }
	if (defined($result)){ return 1 }
	else { return 0}

}


sub getIdxPairInfo($) {
	my $self = shift;
	my ($idxHash) = @_;
	my $dbh = $self->{DBH};

	my $schema = $self->{SCHEMA};

	my $sth = $dbh->prepare($idxInfoSql, {ora_check_sql => 0});
	# prepopulated with 2 index names as keys
	# and array containing schema name
	foreach my $idx ( keys %{$idxHash} ) {
		
		# idxInfoSql is global
		#
		#print "DBI-DEBUG: index name: $idx\n";

		$sth->execute($schema, $schema, $idx);
		#my ($indexName, $bytes, $constraintType) = $idxSth->fetchrow;
		#push @{$idxHash->{$idx}}, $sth->fetchrow_arrayref;

		while (my $ary = $sth->fetchrow_arrayref ) {
			#print "DBI-DEBUG: ", join(' - ', @{$ary}), "\n";
			# bytes, constraint_name, constraint_type
			push @{$idxHash->{$idx}}, ($ary->[2], $ary->[3], $ary->[4]);
			
		}
		$sth->finish;


	}

	#print "DEBUG: getIdxPairInfo" , Dumper($idxHash);

}

1;

