
select count(*) from dba_indexes
where owner in (
	select username
	from dba_users
	where default_tablespace not in ('SYSTEM','SYSAUX')
)
/
