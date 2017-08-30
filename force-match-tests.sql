

set linesize 200 trimspool on
set pagesize 100 

col force_matching_signature format 9999999999999999999999999999 head 'FORCE|MATCH|SIGNATURE'
col exact_matching_signature format 9999999999999999999999999999 head 'EXACT|MATCH|SIGNATURE'
col sql_id format a13
col sql_text format a80


var my_test_bind varchar2(1)

spool force-match-tests.log

prompt ########################
prompt Test 1 - hardcoded 'X'
prompt ########################

select dummy from dual where dummy = 'X';

select sql_id, exact_matching_signature
	, force_matching_signature, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match
	, dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = 'X']';

-----

prompt ########################
prompt Test 2 - hardcoded 'Y'
prompt ########################

select dummy from dual where dummy = 'Y';

select sql_id, exact_matching_signature
	, force_matching_signature, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match
	, dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = 'Y']';

-----

prompt ########################
prompt Test 3 - bind var 'X'
prompt ########################

exec :my_test_bind := 'X';

select dummy from dual where dummy = :my_test_bind;

select sql_id, exact_matching_signature, force_matching_signature
	, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match
	, dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = :my_test_bind]';

-----

prompt ########################
prompt Test 4 - bind var 'Y'
prompt ########################

exec :my_test_bind := 'Y';

select dummy from dual where dummy = :my_test_bind;

select sql_id, exact_matching_signature, force_matching_signature
	, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match 
	,dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = :my_test_bind]';

-----

prompt ########################
prompt Test 5 
prompt   bind var 'X'
prompt   and hardcoded 'X'
prompt ########################

exec :my_test_bind := 'X';

select dummy from dual where dummy = 'X' and dummy = :my_test_bind;

select sql_id, exact_matching_signature, force_matching_signature
	, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match
	, dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = 'X' and dummy = :my_test_bind]';

-----
prompt ########################
prompt Test 6 
prompt   bind var 'Y'
prompt   and hardcoded 'Y'
prompt ########################

exec :my_test_bind := 'Y';

select dummy from dual where dummy = 'Y' and dummy = :my_test_bind;

select sql_id, exact_matching_signature, force_matching_signature
	, decode(force_matching_signature -  exact_matching_signature, 0, 'T','F') exact_match
	, dbms_lob.substr(sql_fulltext,80,1) sql_text
from v$sqlstats
where dbms_lob.substr(sql_fulltext ,80,1) = q'[select dummy from dual where dummy = 'Y' and dummy = :my_test_bind]';

-----


spool off

ed force-match-tests.log

