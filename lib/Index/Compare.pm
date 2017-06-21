
package Index::Compare;

use strict;
use warnings;

use Carp;
use Data::Dumper;
use Generic qw(seriesSum compareAry);

sub getIdxPairInfo($);

my $progressDivisor=10;
my $progressIndicator='.';
my $progressCounter=0;

my %csvColByID = (
	0  =>"Table Owner",
	1	=>"Table Name",
	2	=>"Index Name",
	3	=>"Compared To",
	4	=>"Size",
	5	=>"Constraint Type",
	6	=>"Redundant",
	7	=>"Column Dup%",
	8	=>"Known Used",
	9	=>"Drop Candidate",
	10 =>"Drop Immediately",
	11	=>"Create ColGroup", # 'NA' or 'Y'
	12	=>"Columns", # must always be the last field
	#13	=>"SQL", # must always be last field
);

my %csvColByName = map { $csvColByID{$_} => $_ } keys %csvColByID;

sub buildCsvHdr {
	return map { $csvColByID{$_} } sort { $a <=> $b } keys %csvColByID;
}


#print 'csvColByID ' . Dumper(\%csvColByID);
#print 'csvColByName: ' . Dumper(\%csvColByName);

my $tabSql = q{select
owner || '.' || table_name table_name
from dba_tables
where owner in (
		select username
		from dba_users
		where default_tablespace not in ('SYSTEM','SYSAUX')
	)
	and table_name not like 'DR$%$I%' -- Text Indexes
order by owner, table_name
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

	#croak "Attribute SCHEMA is required in $class::new\n" unless $args{SCHEMA};

	$args{IDX_CHK_TABLE} = 'avail.used_ct_indexes' unless defined($args{IDX_CHK_TABLE});
	$args{RATIO} = 75 unless defined($args{RATIO});
	#
	# SQL to check the table of known used indexes
	$args{IDX_CHK_SQL} =  qq{select owner, index_name
from $args{IDX_CHK_TABLE}
where (owner,index_name) in (?,?)};

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
			$tabSth->execute();
			while ( my $table = $tabSth->fetchrow_arrayref) { 
				# table_name is 'owner.table_name'
				#print "Table: $table->[0]\n";
				push @tables, $table->[0];
			};
			$maxEl = $#tables;
		}

		$el++;
		return ( $el <= $maxEl ) ? $tables[$el] : undef;

	}

}


=head1 %colData

 column data will look like this

  my %colData = (
	  'SHR_INFO_DESID_IDX' =>             ['DEST_ID'],
	  'SHR_INFO_PK' =>                    ['SITE_ID','CLIENT_ID','DEST_ID','ID'],
	  'SHR_INFO_SIT_CLI_TRU_DES_IDX' =>   ['SITE_ID','CLIENT_ID','SYS_NC00015$','DEST_ID'],
	  'SHR_INFO_SIT_CLI_USE_KEY_IDX' =>   ['SITE_ID','CLIENT_ID','USER_KEY'],
	  'SHR_INFO_SI_CL_DE_US_GU_UR_UK' =>  ['SITE_ID','CLIENT_ID','DEST_ID','USER_ID','GUEST_ID','URL'],
	  'SHR_INFO_SI_CL_DE_US_KE_UR_UK' =>  ['SITE_ID','CLIENT_ID','DEST_ID','USER_KEY','URL'],
	  'SHR_INFO_SI_CL_DE_US_TR_IDX' =>    ['SITE_ID','CLIENT_ID','DEST_ID','USER_ID','SYS_NC00015$'],
  );

=cut


sub getIdxColInfo {
	my $self = shift;
	my (%args) = @_;
	my $dbh = $self->{DBH};
	my $rptOut = $args{RPTARY};

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
	push @{$rptOut}, "Getting column Info\n";

	my $colSth = $dbh->prepare($colSql,{ora_check_sql => 0});
	$colSth->execute($self->{OWNER}, $args{TABLE}, $self->{OWNER}, $self->{OWNER}, $args{TABLE});
	
	while ( my $colAry = $colSth->fetchrow_arrayref) { 
		my ($indexName,$columnList) = @{$colAry};

		push @{$rptOut}, "Cols:  $columnList\n";

		push @{$indexes}, $indexName;
		push @{$colData->{$indexName}},split(/,/,$columnList);

	}
}

# check the usage table to see if the index is known to be used.
sub isIdxUsed {
	my $self = shift;
	my $idxOwner = shift;
	my $idxName = shift;
	my $dbh = $self->{DBH};

	my $sth = $dbh->prepare($self->{IDX_CHK_SQL},{ora_check_sql => 0});
	$sth->execute($idxOwner, $idxName);

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

sub processTabIdx {
	my $self = shift;
	my (%args) = @_;
	my $dbh = $self->{DBH};

	my $dirs = $args{DIRS};
	my ($tableOwner,$tableName) = split(/\./,$args{TABLE});
	my $debug = $args{DEBUG};
	my $rptOut = $args{RPTARY};
	my $csvIndexes = $args{CSVHASH};
	my $idxRatioAlertThreshold = $self->{RATIO};
	#my $schema2Chk = $self->{SCHEMA};
	my $schema2Chk = $tableOwner;

	my %colData=();
	my @indexes=();

	push @{$rptOut}, '#' x 120, "\n";
	push @{$rptOut}, "Working on table ${tableOwner}.${tableName}\n";


	#$compare->getIdxColInfo (
	$self->getIdxColInfo (
		OWNER => $tableOwner,
		TABLE => $tableName,
		COLHASH => \%colData,
		IDXARY => \@indexes,
		RPTARY => $rptOut,
	);

	#print 'Col Data: ', Dumper(\%colData) if $debug;
	#print 'Indexes: ', Dumper(\@indexes) if $debug;
	
	if ($debug) {
		push @{$rptOut}, 'Col Data: ';
		foreach my $line ( Dumper(\%colData) ) { push @{$rptOut}, $line }
		push @{$rptOut}, 'Indexes: ';
		foreach my $line ( Dumper(\@indexes) ) { push @{$rptOut}, $line }
	}

	#next;

	# returns 0 if only 1 index
	#print "Number of indexes: " , $#indexes ,"\n";
	push @{$rptOut}, "Number of indexes: " , $#indexes ,"\n";
	if ($#indexes < 1 ) {
		push @{$rptOut}, "Skipping comparison as there is only 1 index on $tableName\n";
		#next TABLE;
		return;
	}

	#next; # debug - skip code

	my $numberOfComparisons = seriesSum($#indexes + 1);

	push @{$rptOut},  "\tNumber of Comparisons to make: $numberOfComparisons\n";

	my $indexesComparedCount=0;
	my @idxInfo=(); # temp storage for data to put in %csvIndexes

	# compare from first index to penultimate index as first of a pair to compare
	IDXCOMP: for (my $idxBase=0; $idxBase < ($#indexes); $idxBase++ ) {

		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		for (my $compIdx=$idxBase+1; $compIdx < ($#indexes + 1); $compIdx++ ) {

			# show progress on terminal
			print STDERR $progressIndicator unless $progressCounter++ % $progressDivisor;

			#my $debug=0;

			# do not compare an index to itself
			# this can happen when a single index is supporting two or more constraints, such as Unique and Primary
			# possibly only if it is also the only index
			# putting code above to skip these
			my $indexesIdentical=0;
			if ($indexes[$idxBase] eq $indexes[$compIdx]) {
				push @{$rptOut}, "Indexes $indexes[$idxBase] and $indexes[$compIdx] are identical\n";
				$indexesIdentical=1;
				next IDXCOMP; # naked 'next' was going to the outer loop - dunno why
			}

			push @{$rptOut}, "\t",'=' x 100, "\n";
			push @{$rptOut}, "\tComparing $indexes[$idxBase] -> $indexes[$compIdx]\n";

			push @{$rptOut}, "\n\tColumn Lists:\n";
			push @{$rptOut}, sprintf("\t %30s: %-200s\n", $indexes[$idxBase], join(' , ', @{$colData{$indexes[$idxBase]}}));
			push @{$rptOut}, sprintf("\t %30s: %-200s\n", $indexes[$compIdx], join(' , ', @{$colData{$indexes[$compIdx]}}));

			$indexesComparedCount++;

			push @{$rptOut}, "IDX 1: ", Dumper($colData{$indexes[$idxBase]}) if $debug;
			push @{$rptOut}, "IDX 2: ", Dumper($colData{$indexes[$compIdx]}) if $debug;

			my @intersection = ();
			my @idx1Diff = ();
			my @idx2Diff = ();

			compareAry($colData{$indexes[$idxBase]}, $colData{$indexes[$compIdx]}, \@intersection, \@idx1Diff, \@idx2Diff);

			if ($debug) {
				push @{$rptOut}, "DIFF 1: ", Dumper(\@idx1Diff);
				push @{$rptOut}, "DIFF 2: ", Dumper(\@idx2Diff);
				push @{$rptOut}, "INTERSECT: ", Dumper(\@intersection);
			}

			push @{$rptOut}, "\n\tColumns found only in $indexes[$idxBase]\n";
			push @{$rptOut}, "\n\t\t", join("\n\t\t",sort @idx1Diff),"\n\n";

			push @{$rptOut}, "\tColumns found only in $indexes[$compIdx]\n";
			push @{$rptOut}, "\n\t\t", join("\n\t\t",sort @idx2Diff),"\n\n";

			push @{$rptOut}, "\tColumns found in both\n";
			push @{$rptOut}, "\n\t\t", join("\n\t\t",sort @intersection),"\n\n";

			my @idxCols1 = @{$colData{$indexes[$idxBase]}};
			my @idxCols2 = @{$colData{$indexes[$compIdx]}};

			# get least number of column count
			my ($leastColCount, $mostColCount);
			my ($leastIdxName, $mostIdxName);

			if ( $#idxCols1 < $#idxCols2 ) {
				$leastColCount = $#idxCols1;
				$mostColCount = $#idxCols2;
				$leastIdxName = $indexes[$idxBase];
				$mostIdxName = $indexes[$compIdx];
			} else {
				$leastColCount = $#idxCols2;
				$mostColCount = $#idxCols1;
				$leastIdxName = $indexes[$compIdx];
				$mostIdxName = $indexes[$idxBase];
			};

			my $leadingColCount = 0;
			foreach my $colID ( 0 .. $leastColCount ) {
				last unless ( $idxCols1[$colID] eq $idxCols2[$colID]);
				$leadingColCount++;
			}

			$idxInfo[$csvColByName{'Table Owner'}] = $tableOwner;
			$idxInfo[$csvColByName{'Table Name'}] = $tableName;
			$idxInfo[$csvColByName{'Index Name'}] = $indexes[$idxBase];
			$idxInfo[$csvColByName{'Compared To'}] = $indexes[$compIdx];
			$idxInfo[$csvColByName{'Size'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Constraint Type'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Redundant'}] = 'N';
			$idxInfo[$csvColByName{'Column Dup%'}] = 0;
			$idxInfo[$csvColByName{'Known Used'}] = 'N';
			$idxInfo[$csvColByName{'Drop Candidate'}] = 'N';
			$idxInfo[$csvColByName{'Drop Immediately'}] = 'N';
			$idxInfo[$csvColByName{'Create ColGroup'}] = 'NA';
			$idxInfo[$csvColByName{'Columns'}] = $colData{$indexes[$idxBase]};
			#$idxInfo[$csvColByName{'SQL'}] = [];


			my $leastColSimilarCountRatio = ( $leadingColCount / ($leastColCount+1)  ) * 100;
			my $leastIdxNameLen = length($leastIdxName);
			my $mostIdxNameLen = length($mostIdxName);
			my $attention='';

			$idxInfo[$csvColByName{'Redundant'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';
			$idxInfo[$csvColByName{'Column Dup%'}] = $leastColSimilarCountRatio;
			$idxInfo[$csvColByName{'Drop Immediately'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';

			if ( $leastColSimilarCountRatio >= $idxRatioAlertThreshold ) {
				$attention = '====>>>> ';
				$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
			}
			push @{$rptOut}, sprintf ("%-10s The leading %3.2f%% of columns for index %${leastIdxNameLen}s are shared with %${mostIdxNameLen}s\n", $attention, $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);
			#push @{$rptOut}, sprintf ("The leading %3.2f%% of columns for index %30s are shared with %30s\n", $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);


			if ( $self->isIdxUsed($indexes[$idxBase]) ) {
				push @{$rptOut}, "Index $indexes[$idxBase] is known to be used in Execution Plans\n";
				$idxInfo[$csvColByName{'Known Used'}] = 'Y';
			} else {
				$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
			}

			if ( $self->isIdxUsed($indexes[$compIdx]) ) {
				push @{$rptOut}, "Index $indexes[$compIdx] is known to be used in Execution Plans\n";
			}

			# check to see if either index is known to support a constraint
			my %idxPairInfo = (
				$leastIdxName => undef,
				$mostIdxName => undef
			);
			$self->getIdxPairInfo(\%idxPairInfo);
			#print '%idxPairInfo: ' , Dumper(\%idxPairInfo);


			# report if any constraints use one or both of the indexes
			foreach my $idxName ( keys %idxPairInfo ) {
				# only 4 possibilities at this time - NONE, R, U, and P
				my ($idxBytes, $constraintName, $constraintType) = @{$idxPairInfo{$idxName}};
				
				my $idxNameLen = length($idxName);
				push @{$rptOut}, sprintf ("The index %${idxNameLen}s is %9.0f bytes\n", $idxName, $idxBytes);

				if ($idxName eq $indexes[$idxBase] ) {
					$idxInfo[$csvColByName{'Size'}] = $idxBytes;
					$idxInfo[$csvColByName{'Constraint Type'}] = $constraintType;
				}

				if ( $constraintType eq 'NONE' ) {
					push @{$rptOut}, "The index $idxName does not appear to support any constraints\n";
				} elsif ( $constraintType eq 'R' ) { # foreign key
						push @{$rptOut}, "The index $idxName supports Foreign Key $constraintName\n";
				} elsif ( $constraintType eq 'U' ) { # unique key
						push @{$rptOut}, "The index $idxName supports Unique Key $constraintName\n";
				} elsif ( $constraintType eq 'P' ) { # primary key
						push @{$rptOut}, "The index $idxName supports Primary Key $constraintName\n";
				} else { 
					warn "Unknown Constraint type of $constraintType!\n";
				}
			}
		} # inner index loop

		push @{$rptOut}, qq{

Debug: csvIndexes
idxInfo[csvColByName{'Table Name'}]: $idxInfo[$csvColByName{'Table Name'}]
idxInfo[csvColByName{'Index Name'}] : $idxInfo[$csvColByName{'Index Name'}] 

		} if $debug;

		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' invisible;';
		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' visible;';

		my $idxDDLFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-invisible.sql';
		my $idxDDLFh = IO::File->new("$dirs->{'indexDDL'}/$idxDDLFile",'w');
		die "Could not create $idxDDLFile\n" unless $idxDDLFh;
		print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' invisible;';

		$idxDDLFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-visible.sql';
		$idxDDLFh = IO::File->new("$dirs->{'indexDDL'}/$idxDDLFile",'w');
		die "Could not create $idxDDLFile\n" unless $idxDDLFh;
		print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' visible;';

		close $idxDDLFh;


=head1 create column group DDL as necessary
		
 The optimizer may be using statistics gathered on index columns during optimization
 even if that index is never used in an execution plan.

 When an index is a drop candidate, and there are no duplicated leading columns, include code to create extended stats
	

=cut
		
		if ( 
			$idxInfo[$csvColByName{'Drop Candidate'}] eq 'Y' 
				and 
			$idxInfo[$csvColByName{'Column Dup%'}] == 0
		) {
			my $columns = join(',',@{$idxInfo[$csvColByName{'Columns'}]});
			my $colgrpDDL = qq{declare extname varchar2(30); begin extname := dbms_stats.create_extended_stats ( ownname => '$schema2Chk', tabname => '$tableName', extension => '($columns)'); dbms_output.put_line(extname); end;};

			push @{$rptOut}, "ColGrp DDL:  $colgrpDDL\n";

			my $colgrpFile = "${tableName}-" . $idxInfo[$csvColByName{'Index Name'}] . '-colgrp.sql';

			my $colgrpFH = IO::File->new("$dirs->{'colgrpDDL'}/$colgrpFile",'w');
			die "Could not create $colgrpFile\n" unless $colgrpFH;

			print $colgrpFH "$colgrpDDL\n";
			close $colgrpFH;

			$idxInfo[$csvColByName{'Create ColGroup'}] = 'Y';
		}

		if ($debug) {
			push @{$rptOut}, 'idxInfo: ';
			foreach my $line ( Dumper(\@idxInfo)) { push @{$rptOut}, $line };
		}

		push @{$csvIndexes->{ $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] }}, @idxInfo;
	} # outer index loop


	push @{$rptOut}, "\tTotal Comparisons Made: $indexesComparedCount\n\n";

	#print "\t!! Number of Comparisons made was $indexesComparedCount - should have been $numberOfComparisons !!\n" if ($numberOfComparisons != $indexesComparedCount );


}

1;

