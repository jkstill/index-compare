select index_name, listagg(column_name,',') within group (order by column_position) column_list
from dba_ind_columns
where index_owner = 'CT'
and table_name = 'SHR_INFO'
group by index_name
/

