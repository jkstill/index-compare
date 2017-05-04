

@@get-schema &1

col index_name format a30
col table_name format a30
col column_list format a140

set linesize 220 trimspool on
set pagesize 100

select ic.table_name
	, ic.index_name
	--, i.dropped
	, listagg(ic.column_name,',') within group (order by column_position) column_list
from dba_ind_columns ic
join dba_indexes i on i.owner = ic.index_owner
	and i.index_name = ic.index_name
where ic.index_owner = '&u_schema'
group by ic.table_name
	--,i.dropped
	, ic.index_name
order by ic.table_name,ic.index_name
/

