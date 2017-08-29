select sql_text 
from dba_hist_sqltext
where sql_id in (
	select sql_id from dba_hist_sqlstat
	where force_matching_signature = 5863951860871718374
)
/
