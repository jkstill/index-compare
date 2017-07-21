
@@get-schema &1

set term on echo off term on feed on
set verify off

set pagesize 100

col table_name format a30
col index_name format a30
col bytes format 999,999,999,999

set linesize 200 trimspool on
set pagesize 100

def b1='#######################################'
def b2='### '

prompt &b1
prompt &b2 Indexes that MAY not be used
prompt &b1

accept dummy prompt 'Press <ENTER> to continue '

spool unused-ct-indexes.txt

break on report
compute sum of bytes on report

with owners as (
	select username
	from dba_users
	where default_tablespace not in ('SYSTEM','SYSAUX')
),
cons_idx as (
	select /*+ no_merge */
		owner,table_name, index_name , constraint_type
	from dba_constraints
	where constraint_type in ('R','U','P')
	and index_name is not null
	and owner in ( 
		select username from owners
	)
)
select i.owner, i.table_name, i.index_name
	, i.leaf_blocks * t.block_size bytes
	, idx.constraint_type -- sanity check - should be all nulls
from dba_indexes i
join dba_tablespaces t on i.tablespace_name = t.tablespace_name
left outer join cons_idx idx on idx.owner = i.owner
	and idx.table_name = i.table_name
	and idx.index_name = i.index_name
where (i.owner,i.index_name) not in (select owner,index_name from &u_schema..used_ct_indexes)
and i.index_type in ('NORMAL','NORMAL/REV','FUNCTION-BASED NORMAL')
and (i.owner, i.table_name, i.index_name) not in (
	select owner, table_name, index_name from cons_idx
)
and i.owner in ( select username from owners)
order by 4 desc
/

spool off

--ed unused-ct-indexes.txt


