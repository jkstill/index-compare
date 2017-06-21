

select
	to_char(timestamp,'yyyy-mm-dd hh24:mi:ss') timestamp
	, sql_id
	, plan_hash_value
	, object_owner
	, object_name
	, object#
	-- no partitions in CT schema
	--, partition_start
	--, partition_stop
	--, partition_id
from gv$sql_plan
where object_owner in (
	select username
	from dba_users
	where default_tablespace not in ('SYSTEM','SYSAUX')
)
	and object_type = 'INDEX'
order by 1
/
