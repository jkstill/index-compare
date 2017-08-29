
col force_matching_signature format 9999999999999999999999999999 head 'FORCE|MATCH|SIGNATURE' 
col exact_matching_signature format 9999999999999999999999999999 head 'EXACT|MATCH|SIGNATURE' 
col sql_id format a13

with force_match as (
	select  distinct
		force_matching_signature
		, sql_id
	--from dba_hist_sqlstat
	from v$sql
)
select force_matching_signature, count(*)
from force_match
group by force_matching_signature
having count(*) > 1
order by 2
/
