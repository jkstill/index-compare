
col plan_line format a200
set linesize 200 trimspool on
set pagesize 100


with plandata as (
	select id, lpad(' ',depth,' ') || operation operation, object_name
	from gv$sql_plan
	where plan_hash_value = 1624682580
	and sql_id = '3p8mthjytxh6n'
	order by id
)
select lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name plan_line
from plandata
group by lpad(id,5,'0') || ' ' || rpad(operation,60,' ') || object_name 
order by 1
/
