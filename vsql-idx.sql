
set num 20
set linesize 300
set pagesize 100

col child_number noprint
col object# format 999999999
col inst_id format 9999 head 'INST|ID'

select distinct
   to_char(max(gsp.timestamp) over (partition by gs.sql_id),'yyyy-mm-dd hh24:mi:ss') timestamp
   , gsp.sql_id
	, min(gs.child_number) over (partition by gs.sql_id) child_number
   , gsp.plan_hash_value
   , gsp.inst_id
   , gsp.object_owner
   , gsp.object_name
   , gsp.object#
	, gs.exact_matching_signature
	, gs.force_matching_signature
   -- partitions not important for this
   --, partition_start
   --, partition_stop
   --, partition_id
from gv$sql_plan gsp
join gv$sql gs on gs.sql_id = gsp.sql_id
	and gs.inst_id = gsp.inst_id
	and gs.plan_hash_value = gsp.plan_hash_value
where gsp.object_owner in (
   select username
   from dba_users
   --where default_tablespace not in ('SYSTEM','SYSAUX')
	where gs.force_matching_signature != 0
	and gsp.object_owner not in ('SYS','SYSMAN')
)
   and object_type = 'INDEX'
   --and timestamp > to_date(?,'yyyy-mm-dd hh24:mi:ss')
order by 1,2,3
/
