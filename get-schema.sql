

-- get-schema.sql
-- get schema name from user and validate it exists
-- 

ttitle off
btitle off
clear break
clear col
set pause off echo off term on

prompt
prompt Create used_ct_indexes in which schema?
prompt

col u_schema new_value u_schema noprint

set echo off term off feed off

select upper('&1') u_schema from dual;

set term on echo off term on feed on



-- this is a bind variable
var return_code varchar2(1);

-- this column command creates the substitution
-- variable 'sqlplus_return_code' when used with
-- a select statement below
col rowcount noprint new_value sqlplus_return_code

whenever sqlerror exit 1

declare
	rowcount integer := 0;
begin

	select count(*) into rowcount from all_users where username = '&u_schema';

	if rowcount != 1 then
		raise_application_error(-20000,'Schema &u_schema does not exist!');
	end if;

end;
/

whenever sqlerror continue

