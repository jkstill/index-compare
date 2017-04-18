


@clear_for_spool

-- column headings
-- not included in file due to use of 'append'
-- epoch can be used for sorting
-- prompt plan_hash_value,sql_id,index_owner,index_name,timestamp,epoch

set term off

spool gv_sql_plan-index-scan.csv append

with indexes as (
	-- horribly slow when the query predicate is pushed
	-- killed after 3-4 minutes on initial query
	-- no_push_pred hint sped it up to 19 seconds
	select /*+ no_push_pred */ index_name
	from dba_indexes
	where table_owner = 'TABLE_OWNER_HERE'
	and table_name in ('TABLE_1', 'TABLE_2' , 'TABLE_3')
)
select
	plan_hash_value
	||','|| sql_id
	||','|| object_owner
	||','|| object_name
	||','|| to_char(sysdate,'yyyy-mm-dd hh24:mi:ss')
	||','|| trim(to_char(( sysdate - date'1970-01-01' ) * 60 * 60 * 24,'999999999999'))
from gv$sql_plan p
where p.object_owner like 'EMTADMIN%'
	and object_type = 'INDEX'
	and object_name in ( select index_name from indexes)
/


spool off
set term on

--ed gv_sql_plan-index-scan.csv

