
-- How to get full sql text statement from v$sql (Doc ID 437304.1)
-- 
-- this is a workaround to getting sql from v$sqltext, as sql_fulltext column is erroneously trimmed (bug) in many 11g versions
--

set linesize 132 pagesize 999
column sql_fulltext format a60 word_wrap 
break on sql_text skip 1 

select 
	replace(translate(sql_fulltext,'0123456789','999999999'),'9','') SQL_FULLTEXT 
from gv$sql 
where sql_id = '8jxxt9p48w0bs'
group by replace(translate(sql_fulltext,'0123456789','999999999'),'9','') 
/


