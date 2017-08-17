
package Index::Compare;

use strict;
use warnings;

use IO::File;
use Carp;
use Data::Dumper;
use Generic qw(seriesSum compareAry);

# prototypes
sub getIdxPairInfo($$);
sub genIdxDDL($$$$);
sub genColGrpDDL($$$$$);
sub genSqlPlans($$$$$$);
#sub genSqlText($$$$);
#sub genPlanText($$$$);
sub createFile($$);

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
	and owner like ?
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
   , nvl(i.leaf_blocks,0) * bs.block_size bytes
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
	# joined do dba_indexes to ensure the index still exists
	$args{IDX_CHK_SQL} =  qq{select u.owner, u.index_name
from $args{IDX_CHK_TABLE} u
join dba_indexes i on i.owner = u.owner
	and i.index_name = u.index_name
where u.owner = ?
	and u.index_name = ?};

	croak "Attribute DBH is required in \$class::new\n" unless $args{DBH};

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
			$tabSth->execute(uc($self->{SCHEMA}));
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
	#warn "owner and table: $args{OWNER} $args{TABLE}\n";

	$colSth->execute($args{OWNER}, $args{TABLE}, $args{OWNER}, $args{OWNER}, $args{TABLE});
	
	while ( my $colAry = $colSth->fetchrow_arrayref) { 
		my ($indexName,$columnList) = @{$colAry};

		push @{$rptOut}, "Cols:  $columnList\n";

		push @{$indexes}, $indexName;
		push @{$colData->{$indexName}},split(/,/,$columnList);

	}
	#
	if ($self->{DEBUG}) {
		print "col Args: " , Dumper(\%args);
		print "self->getIdxColInfo: ", Dumper($self);
	
		print qq{

		getIdxColInfo:
	
		SCHEMA: $args{OWNER}
		TABLE: $args{TABLE}

};
}

}

# check the usage table to see if the index is known to be used.
sub isIdxUsed {
	my $self = shift;
	my $idxOwner = shift;
	my $idxName = shift;
	my $dbh = $self->{DBH};

	#warn "owner and index: $idxOwner, $idxName\n";

	my $sth = $dbh->prepare($self->{IDX_CHK_SQL},{ora_check_sql => 0});
	$sth->execute($idxOwner, $idxName);

	my $result = $sth->fetchrow_arrayref;
	$sth->finish;

	#if ( defined($sth->fetchrow_arrayref)) { return 1 }
	if (defined($result)){ return 1 }
	else { return 0}

}


sub getIdxPairInfo($$) {
	my $self = shift;
	my ($idxHash, $args) = @_;
	my $dbh = $self->{DBH};

	#warn 'getIdxPairInfo Self: ' , Dumper($self);
	#warn "idxHash: ", Dumper($idxHash);
	#warn "Args: ", Dumper($args);

	my $sth = $dbh->prepare($idxInfoSql, {ora_check_sql => 0});
	# prepopulated with 2 index names as keys
	# and array containing schema name
	foreach my $idx ( keys %{$idxHash} ) {
		
		# idxInfoSql is global
		#
		#print "DBI-DEBUG: index name: $idx\n";

		#warn "owner ,table, and index:  $args->{OWNER} $args->{TABLE_NAME} $idx\n";

		$sth->execute($args->{OWNER}, $args->{OWNER}, $idx);
		#my ($indexName, $bytes, $constraintType) = $idxSth->fetchrow;
		#push @{$idxHash->{$idx}}, $sth->fetchrow_arrayref;

		while (my $ary = $sth->fetchrow_arrayref ) {
			#warn "DBI-DEBUG: ", join(' - ', @{$ary}), "\n";
			# bytes, constraint_name, constraint_type
			#warn "bytes, constraint, type: $ary->[2], $ary->[3], $ary->[4]\n";

			push @{$idxHash->{$idx}}, ($ary->[2], $ary->[3], $ary->[4]);
			
		}
		$sth->finish;


	}

	#warn "DEBUG: getIdxPairInfo" , Dumper($idxHash);

}

sub createFile($$) {
	my ($fileName, $fileMode) = @_;
	my $fh = IO::File->new($fileName, $fileMode);
	croak "Could not create $fileName\n" unless $fh;
	return $fh;
}

#sub genSqlText($) {
#my ($schemaName, $sqlId) = @_;
		#my $sqlTextSql=qq(select sql_text from ${schemaName}.used_ct_index_sql where sql_id = ?);
#}

#sub genPlanText($) {
		#my ($schemaName, $planHashValue) = @_;
		#my $planTextSql=qq(select plan_text from ${schemaName}.used_ct_index_plans where plan_hash_value = ?);
#}

sub genSqlPlans($$$$$$) {
	# chkTablesOwner refers to the owners of the tables storing the index info	
	my ($dbh,$chkTablesOwner,$fileDir,$indexOwner,$tableName,$indexName) = @_;
	my ($sqlId,$planHashValue);
	#my $planTextSql=qq(select plan_text from ${chkTablesOwner}.used_ct_index_plans where plan_hash_value = ?);
	my $planExistsSQL=qq{select count(1) index_chk from ${chkTablesOwner}.used_ct_index_sql_plan_pairs where owner = ? and index_name = ?};
	my $planExistsSth=$dbh->prepare($planExistsSQL);
	$planExistsSth->execute($indexOwner,$indexName);
	my ($indexFound) = $planExistsSth->fetchrow_array;
	return unless $indexFound;

	my $sqlPlansFh = createFile("${fileDir}/${indexOwner}-${tableName}-${indexName}.txt",'w');

	my $planPairsSearchSQL=qq{select plan_hash_value, sql_id from ${chkTablesOwner}.used_ct_index_sql_plan_pairs where owner = ? and index_name = ?};
	my $planPairsSearchSth=$dbh->prepare($planPairsSearchSQL);
	$planPairsSearchSth->execute($indexOwner,$indexName);

	# LongReadLen should have been set in dbh by the calling script as we are reading CLOB
	my $sqlSearchSQL = qq{select sql_text from ${chkTablesOwner}.used_ct_index_sql where sql_id = ?};
	my $planSearchSQL = qq{select plan_text from ${chkTablesOwner}.used_ct_index_plans where plan_hash_value = ?};
	my $sqlSearchSth = $dbh->prepare($sqlSearchSQL);
	my $planSearchSth = $dbh->prepare($planSearchSQL);

	while (my $ary = $planPairsSearchSth->fetchrow_arrayref ) {
		($planHashValue,$sqlId) = @{$ary};

		# now lookup up the plans and SQL
		# the Foreign Key constraints guarantee at least one of each exists
		$sqlSearchSth->execute($sqlId);
		my ($sqlText) = $sqlSearchSth->fetchrow_array;

		$planSearchSth->execute($planHashValue);
		my ($planText) = $planSearchSth->fetchrow_array;

		print $sqlPlansFh '=' x 80, "\n";
		print $sqlPlansFh "SQL_ID: $sqlId\n";
		print $sqlPlansFh "Plan Hash Value: $planHashValue\n";
		print $sqlPlansFh "\n=== SQL Text: ===\n\n";
		print $sqlPlansFh "$sqlText\n";
		print $sqlPlansFh "\n=== Plan: ===\n\n";
		print $sqlPlansFh "$planText\n";

	}

	close $sqlPlansFh;

}


sub genIdxDDL ($$$$) { 
	my ($schema2Chk, $tableName, $indexName, $ddlDir) = @_;
	my $idxDDLFh = createFile("${ddlDir}/${schema2Chk}-${tableName}-${indexName}-invisible.sql",'w');
	print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $indexName . ' invisible;';
	$idxDDLFh = createFile("${ddlDir}/${tableName}-${indexName}-visible.sql",'w');
	print $idxDDLFh  'alter index ' . $schema2Chk . '.' . $indexName . ' visible;';
	close $idxDDLFh;
}

sub genColGrpDDL ($$$$$) {
	my ($schema2Chk, $tableName, $indexName, $ddlDir, $columns) = @_;
	my $colgrpDDL = qq{declare extname varchar2(30); begin extname := dbms_stats.create_extended_stats ( ownname => '$schema2Chk', tabname => '$tableName', extension => '($columns)'); dbms_output.put_line(extname); end;};
	my $colgrpFH = createFile("${ddlDir}/${schema2Chk}-${tableName}-" . $indexName . '-colgrp.sql','w');
	print $colgrpFH "$colgrpDDL\n";
	close $colgrpFH;
}



# this function is too big and should be broken up
sub processTabIdx {
	my $self = shift;
	my (%args) = @_;
	my $dbh = $self->{DBH};

	# derive owner from fully qualified table name

	#print "IDX_CHK_TABLE: $self->{IDX_CHK_TABLE}\n";
	my ($chkTablesOwner)=split(/\./,$self->{IDX_CHK_TABLE});
	croak "IDX_CHK_TABLE must be a fully qualified name (owner.tablename) in processTabIdx()\n" unless $chkTablesOwner;
	#print "chkTablesOwner: $chkTablesOwner\n";


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


	$|=1;

	#warn "owner and table $tableOwner $tableName\n";


	#$compare->getIdxColInfo (
	$self->getIdxColInfo (
		OWNER => $tableOwner,
		TABLE => $tableName,
		COLHASH => \%colData,
		IDXARY => \@indexes,
		RPTARY => $rptOut,
	);

	my $genIndexDDL = $self->{GEN_INDEX_DDL};
	my $genColGrpDDL = $self->{GEN_COLGRP_DDL};
	my $genSqlPlans = $self->{GEN_SQL_PLANS};

	print qq {

	sub processTabIdx
	 genIndexDDL: $genIndexDDL
	genColGrpDDL: $genColGrpDDL
	
	} if $debug;


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
	push @{$rptOut}, "Number of indexes: " , ($#indexes + 1) ,"\n";
	if ($#indexes == 0 ) {
		push @{$rptOut}, "Skipping comparison as there is only 1 index on $tableName\n";
		#next TABLE;
		return;
	}

	if ($#indexes < 0 ) {
		push @{$rptOut}, "Skipping comparison as there are no indexes $tableName\n";
		#next TABLE;
		return;
	}

	#next; # debug - skip code

	my $numberOfComparisons = seriesSum($#indexes + 1);

	push @{$rptOut},  "\tNumber of Comparisons to make: $numberOfComparisons\n";

	my $indexesComparedCount=0;
	my @idxInfo=(); # temp storage for data to put in %csvIndexes

	# compare from first index to penultimate index as first of a pair to compare
	#IDXCOMP: for (my $idxCounter=0; $idxCounter < $#indexes; $idxCounter++ ) 
	IDXCOMP: for (my $idxCounter=0; $idxCounter <= $#indexes; $idxCounter++ ) {

		my $idxBase = $idxCounter;

		# start with first index, compare columns to the rest of the indexes
		# then go to next index and compare to successive indexes
		# when the outer loop is on the last iteration, set the @bc array to 0 
		# so that the the final index in the array for the table - $indexes[$#indexes] = is compared to the first index only -  $indexes[0]
		# doing so causes that index to appear in the CSV output
		#
		# see idx-loop-compare.pl for a demo of this
	
		my @bc=($idxBase+1 .. $#indexes);

		if ($idxCounter == $#indexes) { @bc=(0) }

		foreach my $idxCounter2 ( @bc ) {

			my $compIdx = $idxCounter2;

			# show progress on terminal
			print STDERR $progressIndicator unless $progressCounter++ % $progressDivisor;

			#my $debug=0;

			# do not compare an index to itself
			# this can happen when a single index is supporting two or more constraints, such as Unique and Primary
			# possibly only if it is also the only index
			if ($indexes[$idxBase] eq $indexes[$compIdx]) {
				push @{$rptOut}, "Indexes $indexes[$idxBase] and $indexes[$compIdx] are identical\n";
				next IDXCOMP;
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

			# +1 to get actual account due to zero based array index
			if ( $#idxCols1 < $#idxCols2 ) {
				$leastColCount = $#idxCols1 + 1;
				$mostColCount = $#idxCols2 + 1;
				$leastIdxName = $indexes[$idxBase];
				$mostIdxName = $indexes[$compIdx];
			} else {
				$leastColCount = $#idxCols2 + 1;
				$mostColCount = $#idxCols1 + 1;
				$leastIdxName = $indexes[$compIdx];
				$mostIdxName = $indexes[$idxBase];
			};

#push @{$rptOut},  qq{

  #leastColCount: $leastColCount
  #mostColCount: $mostColCount
  #leastIdxName: $leastIdxName
      #first column: $idxCols1[0]
  #mostIdxName: $mostIdxName
      #first column: $idxCols2[0]

#};

			my $leadingColCount = 0;
			foreach my $colID ( 0 .. ($leastColCount - 1)) {
				last unless ( $idxCols1[$colID] eq $idxCols2[$colID]);
				$leadingColCount++;
			}

			$idxInfo[$csvColByName{'Table Owner'}] = $tableOwner;
			$idxInfo[$csvColByName{'Table Name'}] = $tableName;
			$idxInfo[$csvColByName{'Index Name'}] = $indexes[$idxBase];
			$idxInfo[$csvColByName{'Compared To'}] = $indexes[$compIdx];
			$idxInfo[$csvColByName{'Size'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Constraint Type'}] = 'NA'; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Redundant'}] = 'N';
			$idxInfo[$csvColByName{'Column Dup%'}] = 0;
			$idxInfo[$csvColByName{'Known Used'}] = 'N';
			$idxInfo[$csvColByName{'Drop Candidate'}] = 'N';
			$idxInfo[$csvColByName{'Drop Immediately'}] = 'N';
			$idxInfo[$csvColByName{'Create ColGroup'}] = 'NA';
			$idxInfo[$csvColByName{'Columns'}] = $colData{$indexes[$idxBase]};
			#$idxInfo[$csvColByName{'SQL'}] = [];


			#my $leastColSimilarCountRatio = ( $leadingColCount / ($leastColCount+1)  ) * 100;
			my $leastColSimilarCountRatio = ( $leadingColCount / $leastColCount  ) * 100;
			my $leastIdxNameLen = length($leastIdxName);
			my $mostIdxNameLen = length($mostIdxName);
			my $attention='';

			if ( $leastIdxName eq $indexes[$idxBase] ) {
				$idxInfo[$csvColByName{'Redundant'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';
				$idxInfo[$csvColByName{'Column Dup%'}] = $leastColSimilarCountRatio;
				$idxInfo[$csvColByName{'Drop Immediately'}] = $leastColSimilarCountRatio == 100 ? 'Y' : 'N';

				if ( $leastColSimilarCountRatio >= $idxRatioAlertThreshold ) {
					$attention = '====>>>> ';
					$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
				}
			} else {

#push @{$rptOut},  qq{

#leastColCount: $leastColCount
#leadingColCount: $leadingColCount


#};

=head1 Column Duplication %

 This bit of code is used to determine the percentage of leading columns from one index that are reproduced in another index

 Say we have the following table with 2 indexes

 mytab
 c1
 c2
 c3
 c4
 c5

 idx1(c1,c2)
 idx2(c1,c2,c3,c4)

 it is clearly seen in this example that 100% of the columns in idx1 are reproduced in idx2.
 therefor the idx1 index has a redundant column list and *may* not be nessary

 now consider these indexes

 idx1(c1,c2,c5)
 idx2(c1,c2,c3,c4)

 now only the 2 leading columns in idx1 are duplicated in idx2.

 the percentage of duplicate columns is 66.6%.

 2 = number of leading columns in idx1 duplicated in the leading columns of idx2
 3 = total number of columns in idx1

 pct of idx1 columns duplidated in idx2:
 
   leadingColCount / idxColCount * 100

   2 / 3 * 100 = 66.6



=cut

				# is this not lovely? 
				# standard pct:  leadingColCount / leastColCount * 100
				# but, the idx with the least number of columns may be the one the current index is being compared to
				# this would tend to fix false positives for considering the index under consideration as eligible to be dropped.
				# if that is the case, multiply by 0 rather than 100
				$idxInfo[$csvColByName{'Column Dup%'}] = ( $leadingColCount / $leastColCount ) * ( $leastIdxName eq $indexes[$idxBase] ? 100 : 0 );

				# this one is incorrect
				#$idxInfo[$csvColByName{'Column Dup%'}] = ( $leastColCount / ($leadingColCount > 0 ? $leadingColCount : 1)  ) * ( $leadingColCount > 0 ? 100 : 0); 
			}

			push @{$rptOut}, sprintf ("%-10s The leading %3.2f%% of columns for index %${leastIdxNameLen}s are shared with %${mostIdxNameLen}s\n", $attention, $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);
			#push @{$rptOut}, sprintf ("The leading %3.2f%% of columns for index %30s are shared with %30s\n", $leastColSimilarCountRatio, $leastIdxName, $mostIdxName);


			if ( $self->isIdxUsed($tableOwner,$indexes[$idxBase]) ) {
				push @{$rptOut}, "Index $indexes[$idxBase] is known to be used in Execution Plans\n";
				$idxInfo[$csvColByName{'Known Used'}] = 'Y';
			} else {
				$idxInfo[$csvColByName{'Drop Candidate'}] = 'Y';
			}

			if ( $self->isIdxUsed($tableOwner,$indexes[$compIdx]) ) {
				push @{$rptOut}, "Index $indexes[$compIdx] is known to be used in Execution Plans\n";
			}

			# check to see if either index is known to support a constraint
			my %idxPairInfo = (
				$leastIdxName => undef,
				$mostIdxName => undef
			);
			$self->getIdxPairInfo(\%idxPairInfo, { OWNER => $tableOwner, TABLE_NAME => $tableName } );
			#warn '%idxPairInfo: ' , Dumper(\%idxPairInfo);


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

			#last if ($idxBase == $#indexes );
		} # inner index loop

		#print "TMP DEBUG: Owner: $tableOwner\n";
		#print "TMP DEBUG: Table: $tableName\n";
		push @{$rptOut}, qq{

Debug: csvIndexes
idxInfo[csvColByName{'Table Name'}]: $idxInfo[$csvColByName{'Table Name'}]
idxInfo[csvColByName{'Index Name'}] : $idxInfo[$csvColByName{'Index Name'}] 

		} if $debug;



		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' invisible;';
		#push @{$idxInfo[$csvColByName{'SQL'}]}, 'alter index ' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . ' visible;';

#print STDERR "\n DEBUG idxInfo:", Dumper(\@idxInfo),"\n";

		# generate ddl for indexes - make invisible/visible
		genIdxDDL($schema2Chk, $tableName, $idxInfo[$csvColByName{'Index Name'}],$dirs->{'indexDDL'}) if $genIndexDDL;

		if ($genSqlPlans) {
			genSqlPlans($dbh,$chkTablesOwner,$dirs->{'sqlPlanFiles'},$schema2Chk,$tableName,$idxInfo[$csvColByName{'Index Name'}]);
		}

=head1 create column group DDL as necessary
		
 The optimizer may be using statistics gathered on index columns during optimization
 even if that index is never used in an execution plan.

 When an index is a drop candidate, and there are no duplicated leading columns, include code to create extended stats
	

=cut
		
		if ( 
			$idxInfo[$csvColByName{'Drop Candidate'}] eq 'Y' 
				and 
			$idxInfo[$csvColByName{'Column Dup%'}] == 0
				and
			$genColGrpDDL
		) {
			my $columns = join(',',@{$idxInfo[$csvColByName{'Columns'}]});
			# generate ddl for column groups

			my  $colgrpDDL = genColGrpDDL($schema2Chk, $tableName, $idxInfo[$csvColByName{'Index Name'}], $dirs->{'colgrpDDL'},  $columns);
			push @{$rptOut}, "ColGrp DDL:  $colgrpDDL\n";
			$idxInfo[$csvColByName{'Create ColGroup'}] = 'Y';

		} else {
			if ($debug) {
				print qq {
					Drop Candidate: $idxInfo[$csvColByName{'Drop Candidate'}]
					Column Dup%   : $idxInfo[$csvColByName{'Column Dup%'}]
					Generate?     : $genColGrpDDL
				};
			}
		}

		if ($debug) {
			push @{$rptOut}, 'idxInfo: ';
			foreach my $line ( Dumper(\@idxInfo)) { push @{$rptOut}, $line };
		}


		#push @{$csvIndexes->{ $tableOwner . '.' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] }}, @idxInfo;
		push @{$csvIndexes->{ $tableOwner . '.' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] . '.' . $idxInfo[$csvColByName{'Constraint Type'}] }}, @idxInfo;

	} # outer index loop

=head1 this is the code to catch the last index - I do not like this, but have not yet got another method to work correctly

			# reuse this bit just to get bytes
			my %idxPairInfo = (
				$indexes[$#indexes] => undef,
				$indexes[0] => undef
			);
			$self->getIdxPairInfo(\%idxPairInfo, { OWNER => $tableOwner, TABLE_NAME => $tableName } );

			my ($idxBytes) = @{$idxPairInfo{$indexes[$#indexes]}};

			$idxInfo[$csvColByName{'Table Owner'}] = $tableOwner;
			$idxInfo[$csvColByName{'Table Name'}] = $tableName;
			$idxInfo[$csvColByName{'Index Name'}] = $indexes[$#indexes];
			$idxInfo[$csvColByName{'Compared To'}] = 'NA';
			$idxInfo[$csvColByName{'Size'}] = $idxBytes; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Constraint Type'}] = 0; # only populated if a drop candidate
			$idxInfo[$csvColByName{'Redundant'}] = 'N';
			$idxInfo[$csvColByName{'Column Dup%'}] = 0;
			$idxInfo[$csvColByName{'Known Used'}] = 'N';
			$idxInfo[$csvColByName{'Drop Candidate'}] = 'N';
			$idxInfo[$csvColByName{'Drop Immediately'}] = 'N';
			$idxInfo[$csvColByName{'Create ColGroup'}] = 'NA';
			$idxInfo[$csvColByName{'Columns'}] = $colData{$indexes[$#indexes]};
			#$idxInfo[$csvColByName{'SQL'}] = [];

		push @{$csvIndexes->{ $tableOwner . '.' . $idxInfo[$csvColByName{'Table Name'}] . '.' . $idxInfo[$csvColByName{'Index Name'}] }}, @idxInfo;

=cut

	push @{$rptOut}, "\tTotal Comparisons Made: $indexesComparedCount\n\n";

	#print "\t!! Number of Comparisons made was $indexesComparedCount - should have been $numberOfComparisons !!\n" if ($numberOfComparisons != $indexesComparedCount );

}

1;

