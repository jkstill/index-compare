

@@get-schema &1

select
	to_char(timestamp,'yyyy-mm-dd hh24:mi:ss') timestamp
	, sql_id
	, plan_hash_value
	--, object_owner
	, object_name
	, object#
	-- no partitions in CT schema
	--, partition_start
	--, partition_stop
	--, partition_id
from gv$sql_plan
where object_owner = '&u_schema'
	and object_type = 'INDEX'
order by 1
/
