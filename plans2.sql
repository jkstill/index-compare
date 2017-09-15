

set linesize 400 trimspool on
set pagesize 50000
set long 2000000

col  sql_id format a13
col sql_text format a100
col plan_text format a110

def u_owner = 'OE'
def u_index = 'I_TRIGGER1'

break on md5_hash skip page

spool j.log

select 
	sql.md5_hash
	--, i.owner
	--, i.index_name
	, sql.sql_id
	, sql.sql_text
	, pl.plan_hash_value 
	, pl.plan_text 
from used_ct_indexes i
join used_ct_index_sql_plan_pairs pp on pp.owner = i.owner
	and pp.index_name = i.index_name
join used_ct_index_sql sql on sql.md5_hash = pp.md5_hash
join used_ct_index_plans pl on pl.plan_hash_value = pp.plan_hash_value
where i.owner = '&u_owner'
	and i.index_name = '&u_index'
--where sql.md5_hash = '28373fc9fedcf344faa58ec7412252f7'
order by sql.md5_hash, pl.plan_hash_value
/


@showplan_last

spool off


ed j.log

