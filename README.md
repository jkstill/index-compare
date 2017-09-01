
<h2>== track index usage ==</h2>

Sometimes a schema is overindexed - it happens.

Detecting which indexes are candidates for removal is not straight forward.

There are many factors involved.

For instance, an index that appears to be unused may actually be used only 4 times a year for quarter end processing.

Successfully detecting that fact requires at least 3 months of monitoring.

A possibility may be to drop that index and recreate it every quarter.

That is a judgment call as it is not always possible to do that.
Consider the case of a 5TiB table with hundreds of partitions, each of which is sub-partitioned.
That is not an index you would like to recreate.

It may be possible to achieve this index monitoring via Oracle Index Monitor.

In the past that was not necessarily the most reliable method. 
That may have changed, I have not checked.

Another consideration is the overhead that may be imposed by the index monitoring.
I would expect that to be minimal, but have not tested it.

There is a scenario that can occur where index usage does not appear in the execution plan:
When an index is used to support a foreign key, DML may make use of the index, but the index will not appear in the execution plan.


The method used here:

<pre>

- Monitor gv$sql_plan and look for indexes being used by the schema being monitored.
  These index names can be saved to a table for later operations, such as looking for unused indexes
  the script unused-ct-indexes.sql does this by scanning the list of known used indexes for exclusion
  from the report of possible candidates.
  Also excluded are indexes reported as supporting constraints, LOB segments and Text indexes
- analyze the schemas 
  index-compare.pl analyzes indexes and reports where at least 75% of the leading columns are identical between 2 indexes
  <probably more to come for this>
</pre>

<h3>-- Workflow</h3>

<h4>create the used_ct_indexes table:</h4>
  <pre>
  create-ct-index-table.sql

  this table just tracks index names that are logged in the output file of the next step
  populating this table is done via a later script

  input: provide a schema name where the tracking table is to be located
  </pre>

<h4>collect index stats from v$sql_plan:</h4>
  <pre>

  vsql-idx.pl now does the work formerly done by ct-index-insert.pl, as well as some other things.

  This section needs to be updated with a description of what is now done by this script.

  vsql-idx.sh LOCAL_ORACLE_HOME DATABASE USERNAME SCHEMA

  LOCAL_ORACLE_HOME: used to call oraenv to set local environment
  DATABASE         : which database to connect to
  USERNAME         : username to connect with
  SCHEMA           : schema name to check


  The vsql-idx.sh script will prompt for password.

  The script will then run in a loop, sleeping for 5 minutes and then running vsql-idx.pl.

  There is no need to run this in the background with nohup as this is done within the script.
  
  example: vsql-idx.sh   c12 p1 jkstill jkstill


  change the iteration value to determine how long this will run
  runs every 5 minutes so ~ 288 times per day
  </pre>
    
<h4>monitor progress:</h4>
  <pre>
  -- current number of appearances in gv$sql_plan by an index - only those that appear 21+ times
  tail -n +2 vsql-idx.csv | cut -f5-6 -d, | sort | uniq -c | sort -n | awk '{ if ($1 > 0) printf("%5d %30s\n", $1 ,$2, $3) }'
  
  -- count of indexes that have so far appeared in gv$sql
  tail -n +2 vsql-idx.csv | cut -f5-6 -d, | sort -u | wc -l
  </pre>


<h4>insert into used_ct_indexes table</h4>
  <pre>

  DEPRECATED - now done by vsql-idx.pl

  ct-index-insert.sh LOCAL_ORACLE_HOME DATABASE USERNAME SCHEMA

  LOCAL_ORACLE_HOME: used to call oraenv to set local environment
  DATABASE         : which database to connect to
  USERNAME         : username to connect with
  SCHEMA           : schema name to check

  example: ./ct-index-insert.sh  c12 p1 jkstill jkstill
 
  The script will prompt for password

  This shell script calls ct-index-insert.pl and can be run as many times as needed 


  </pre>

<h4>check for potentially unused indexes</h4>
  <pre>
  unused-ct-indexes.sql

  this script ignores LOB indexes, and indexes with a _PK or _UK suffix
  </pre>

<h4>analyze the schemas</h4>
  <pre>
  index-compare.pl analyzes indexes and reports where at least 75% of the leading columns are identical between 2 indexes

  While running a text report is sent to STDOUT.

  A csv file may also be created via the --csv-file parameter

  In addition 2 directories are created:
   index_ddl/
   column-group-ddl/

  Within each directory is place SQL code as per the following explanation.

<h3> Make indexes invisible</h3>

For the time being the code generated being generated is in two files per index.
(see attached zip file)

index-ddl/TABLE_NAME-INDEX_NAME-invisible.sql
index-ddl/TABLE_NAME-INDEX_NAME-visible.sql

Code to drop the indexes can be added, but I want to also include code to recreate the index if needed.
Just now I am getting the results I expect for the output, and have not yet gotten to the drop/recreate code.

The DROP code needs to consider too if an constraint is being supported by an index.
If so, then another index (the 'Compared To' index most likely) will be assigned to the constraint.

<h3>Column Group creation</h3>

The optimizer may be using statistics gathered on index columns during optimization even if that index is never used in an execution plan.

When an index is a drop candidate, and there are no duplicated leading columns, include code to create extended stats

The code is placed in a file:

column-group-ddl/TABLE_NAME-INDEX_NAME-colgrp.sql

example:

<h4>column-group-ddl/USER_INFLUENCE-USER_INFLUENCE_DDVACNSA_IDX-colgrp.sql</h4>

<blockquote style='border: 2px solid #000;background-color:#A9F5F2;color:#0B0B61; white-space: pre-wrap;'>
<pre><code><i>
declare extname varchar2(30); begin extname := dbms_stats.create_extended_stats ( ownname => 'SCOTT', tabname => 'SOMETABLE', extension => '(COL1,COL2,COL3)'); dbms_output.put_line(extname); end;
</i></code></pre>
</blockquote>

<h3>How it Works</h3>

The script examines all indexes for a schema

For each table, all indexes are compared to all other indexes.

They are compared in this order:
- supporting a constraint
- supporting a referential constraint
- supporting a unique constraint
- supporting a primary constraint

If a table has only 1 index, no comparison is done.

Program logic then looks for criteria that may be used to mark the index as a candidate for dropping.

Note: comparing indexes always starts with the first column in each index

Main rules:

Only 'NORMAL' indexes are being considered, that is standard B*Tree indexes.

- if 100% of columns are duplicated in another index in the same order, the index is marked redundant and as drop immediately
- if 75% (default) of columns are duplicated in another index in the same order, the index is marked as candidate to be dropped
- if none of the columns are duplicated in another index, and the index has never been used, it is marked as a drop candidate and column group PL/SQL generated

There are other rules that may come into play as well.


<h3>explanation of spreadsheet columns</h3>

Some are self explanatory and will not be documented here.

<h4>Compared To</h4>

This is the index that was compared to the index under examination.
Note: not all indexes appear in this report.

<h4>Constraint Type</h4>

The type of constraint the index is supporting.

U: Unique Constraint
R: Foreign Key
P: Primary Key
NONE: none

<h4>Redundant</h4>

If all of the columns in the index are 100% contained in the 'Compared To' index, and they are in the same order from the first column on, then the index is flagged as redundant ad as 'drop immediately'.

This is currently true even of indexes that known to have been used.

On reflection it may be a good idea to not set the 'drop immediately' flag if the index has been used.

<h4>Column Dup%</h4>

When comparing the column list for 2 indexes, a percentage of duplication is calculated.

Given these 2 indexes:

idx_1: c1,c2,c3,c4,c5
idx_2: c1,c2,c3

The first 3 columns of idx_1 are duplicated in idx_2.

3/5*100 = 60

So there is 60% duplication of the columns of idx_1 when compared to idx_2.

It may be possible to drop the index. 
The default threshold in the script is 75%.


<h4>Known Used</h4>

Index usage has been harvested from gv$sql_plan since 2017-04-18  
(currently it is 2017-05-03)

Indexes that have not appeared there are shown as Unused.


</pre>

<h3>To Do</h3>

<pre>

- optionally output execution plans from gv$sql_plan
- optionally output execution plans from dba_hist_sql_plan


</pre>



  </pre>



