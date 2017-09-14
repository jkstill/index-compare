
@@get-schema avail


/*

################################
## USED_CT_INDEX_SQL_PLAN_PAIRS
################################

 Name																					 Null?	 Type
 ----------------------------------------------------------------- -------- --------------------------------------------
 OWNER																				 NOT NULL VARCHAR2(30 CHAR)
 INDEX_NAME																			 NOT NULL VARCHAR2(30 CHAR)
 PLAN_HASH_VALUE																	 NOT NULL NUMBER
 SQL_ID																				 NOT NULL VARCHAR2(13 CHAR)
 FORCE_MATCHING_SIGNATURE																	 NUMBER
 MD5_HASH																						 VARCHAR2(32 CHAR)

################################
## USED_CT_INDEX_SQL
################################

 Name																					 Null?	 Type
 ----------------------------------------------------------------- -------- --------------------------------------------
 SQL_ID																				 NOT NULL VARCHAR2(13 CHAR)
 SQL_TEXT																						 CLOB
 FORCE_MATCHING_SIGNATURE																	 NUMBER
 EXACT_MATCHING_SIGNATURE																	 NUMBER
 MD5_HASH																						 VARCHAR2(32 CHAR)

################################
## USED_CT_INDEX_PLANS
################################
 Name									Null?		Type
 ----------------------------------------------------------------- -------- --------------------------------------------
 PLAN_HASH_VALUE							NOT NULL NUMBER
 PLAN_TEXT									 CLOB


*/


set pagesize 100
set linesize 300 trimspool on
set long 200000
set verify off echo off pause off

col_sql_id format a13
col sql_text format a100
col plan_hash_value format 999999999999
col plan_text format a110

break on sql_id on sql_text

set term off

spool plans.log

select sql.sql_id
	, sql.sql_text
	--, sql.md5_hash
	, pl.plan_hash_value 
	, pl.plan_text 
from &u_schema..used_ct_index_sql sql 
join &u_schema..used_ct_index_sql_plan_pairs pp on pp.md5_hash = sql.md5_hash
join &u_schema..used_ct_index_plans pl on pl.plan_hash_value = pp.plan_hash_value
where rownum <= 100
order by sql.sql_id, pl.plan_hash_value
/

spool off

set term on

ed plans.log
