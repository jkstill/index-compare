
@@get-schema &1

select count(*) from dba_indexes
where owner = '&u_schema'
/
