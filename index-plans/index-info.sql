
col num_distinct format 999,999,999,999,999
col num_rows format 999,999,999,999,999
col columnname format a15
col cardinality format 999,999,999,999,999.9

select
	a.table_name,
	a.index_name indexname,
	a.compression,
	b.column_name columnname,
	b.column_position columnpos,
	c.num_distinct,
	a.num_rows,
	a.num_rows / c.num_distinct cardinality
from dba_indexes a, dba_ind_columns b, dba_tab_columns c
where  a.table_name = b.table_name
	and a.index_name = b.index_name
	and a.owner = 'TABLE_OWNER_HERE'
	and b.index_owner = 'INDEX_OWNER_HERE'
	and c.owner = b.index_owner
	and c.table_name = b.table_name
	and c.column_name = b.column_name
and a.index_name in (
	select index_name
		from dba_indexes
			where table_owner = 'TABLE_OWNER_HERE'
				and table_name in ('TABLE_1', 'TABLE_2' , 'TABLE_3')
)
order by a.table_name,a.index_name, b.column_position
/
