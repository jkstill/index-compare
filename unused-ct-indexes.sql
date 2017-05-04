

@@get-schema &1

set term on echo off term on feed on

set pagesize 100

col table_name format a30
col index_name format a30
col bytes format 999,999,999,999

set linesize 200 trimspool on
set pagesize 100

def b1='#######################################'
def b2='### '

prompt &b1
prompt &b2 CT Indexes that MAY not be used
prompt &b1

accept dummy prompt 'Press <ENTER> to continue '

break on report
compute sum of bytes on report

with cons_idx as (
	select /*+ no_merge */
		table_name, index_name , constraint_type
	from dba_constraints
	where owner = '&u_schema'
	and constraint_type in ('R','U','P')
	and index_name is not null
)
select i.table_name, i.index_name
	, i.leaf_blocks * t.block_size bytes
	, idx.constraint_type -- sanity check - should be all nulls
from dba_indexes i
join dba_tablespaces t on i.tablespace_name = t.tablespace_name
left outer join cons_idx idx on idx.table_name = i.table_name
	and idx.index_name = i.index_name
where i.owner = '&u_schema'
and i.index_name not in (select * from &u_schema..used_ct_indexes)
and i.index_type in ('NORMAL','NORMAL/REV','FUNCTION-BASED NORMAL')
-- not going to rely on index naming convention
--and index_name not like '%\_UK' escape '\'  -- Unique Keys - a fortunate naming convention
--and index_name not like '%\_PK' escape '\'  -- Primary Keys - a fortunate naming convention
and (i.table_name, i.index_name) not in (
	select table_name, index_name from cons_idx
)
order by 3
/


