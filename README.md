
Track Index Usage
=================

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

Something else to keep in mind is that it is not really possible to determine if in index will ever be used by an application, even if that index that has not been used in some period of time.

Following are some details of how indexes are being monitored with this app.

## Monitor gv$sql_plan 

### look for indexes being used by the schema being monitored

These index names can be saved to a table for later operations, such as looking for unused indexes
the script unused-ct-indexes.sql does this by scanning the list of known used indexes for exclusion
from the report of possible candidates.
Also excluded are indexes reported as supporting constraints, LOB segments and Text indexes

### Analyze the schemas 

`index-compare.pl` analyzes indexes and reports where at least 75% of the leading columns are identical between 2 indexes.


## Workflow

### Create the used_ct_indexes table


`Create-ct-index-table.sql`

This table just tracks index names that are logged in the output file of the next step, populating this table is done via a later script.

input: provide a schema name where the tracking table is to be located


### Collect index stats from v$sql_plan


  `vsql-idx.pl` now does the work formerly done by `ct-index-insert.pl`, as well as some other things.

  Note: This section needs to be updated with a description of what is now done by this script.

  vsql-idx.sh LOCAL_ORACLE_HOME DATABASE USERNAME SCHEMA

  LOCAL_ORACLE_HOME: used to call oraenv to set local environment
  DATABASE         : which database to connect to
  USERNAME         : username to connect with
  SCHEMA           : schema name to check


The `vsql-idx.sh` script will prompt for password.

The script will then run in a loop, sleeping for 5 minutes and then running vsql-idx.pl.

There is no need to run this in the background with nohup as this is done within the script.
 
example: `vsql-idx.sh   c12 p1 jkstill jkstill`


change the iteration value to determine how long this will run

Currently runs every 10 minutes so ~ 144 times per day

See the top of the script to alter frequency and the number of iterations.

    
### monitor progress


#### current number of appearances in gv$sql_plan by an index - only those that appear 21+ times

```text
$  tail -n +2 csv/vsql-idx.csv | cut -f5-6 -d, | sort | uniq -c | sort -n | awk '{ if ($1 > 0) printf("%5d %30s\n", $1 ,$2, $3) }'
    1                    1,ORACLEDBA
    3                  1,APEX_030200
    3                  1,FLOWS_FILES
    3                      1,OLAPSYS
    3                          1,XDB
    4                           1,SH
    8                        1,MDSYS
   10                       1,SYSTEM
   11                        1,AVAIL
  123                       1,SYSMAN
  239                          1,SYS
```

  
  
#### count of indexes that have so far appeared in gv$sql

```text
$  tail -n +2 csv/vsql-idx.csv | cut -f5-6 -d, | sort -u | wc -l
11
```

### insert into used_ct_indexes table

!! DEPRECATED - now done by vsql-idx.pl !!

ct-index-insert.sh LOCAL_ORACLE_HOME DATABASE USERNAME SCHEMA

LOCAL_ORACLE_HOME: used to call oraenv to set local environment
DATABASE         : which database to connect to
USERNAME         : username to connect with
SCHEMA           : schema name to check

example: ./ct-index-insert.sh  c12 p1 jkstill jkstill
 
The script will prompt for password

This shell script calls ct-index-insert.pl and can be run as many times as needed 


### Check for potentially unused indexes

`unused-ct-indexes.sql`

This script ignores LOB indexes, and indexes with a _PK or _UK suffix.

### Analyze the schemas

`index-compare.pl` analyzes indexes and reports where at least 75% of the leading columns are identical between 2 indexes

While running a text report is sent to STDOUT.

A csv file may also be created via the --csv-file parameter

In addition 2 directories are created:
* index_ddl/
* column-group-ddl/

Within each directory is place SQL code as per the following explanation.

## Make indexes invisible

For the time being the code generated being generated is in two files per index.
(see attached zip file)

* index-ddl/TABLE_NAME-INDEX_NAME-invisible.sql
* index-ddl/TABLE_NAME-INDEX_NAME-visible.sql

Code to drop the indexes can be added, but I want to also include code to recreate the index if needed.
Just now I am getting the results I expect for the output, and have not yet gotten to the drop/recreate code.

The DROP code needs to consider too if an constraint is being supported by an index.
If so, then another index (the 'Compared To' index most likely) will be assigned to the constraint.

## Column Group creation

The optimizer may be using statistics gathered on index columns during optimization even if that index is never used in an execution plan.

When an index is a drop candidate, and there are no duplicated leading columns, include code to create extended stats'

The code is placed in a file:

example:

```text
$ cat column-group-ddl/HR-EMPLOYEES-EMP_MANAGER_IX-colgrp.sql
```

```sql
declare extname varchar2(30); begin extname := dbms_stats.create_extended_stats ( ownname => 'HR', tabname => 'EMPLOYEES', extension => '(MANAGER_ID)'); dbms_output.put_line(extname); end;
```

## How it Works

The script examines all indexes for a schema

For each table, all indexes are compared to all other indexes.

They are compared in this order:
* supporting a constraint
* supporting a referential constraint
* supporting a unique constraint
* supporting a primary constraint

If a table has only 1 index, no comparison is done.

Program logic then looks for criteria that may be used to mark the index as a candidate for dropping.

Note: comparing indexes always starts with the first column in each index

Main rules:

Only 'NORMAL' indexes are being considered, that is standard B*Tree indexes.

* if 100% of columns are duplicated in another index in the same order, the index is marked redundant and as drop immediately
* if 75% (default) of columns are duplicated in another index in the same order, the index is marked as candidate to be dropped
* if none of the columns are duplicated in another index, and the index has never been used, it is marked as a drop candidate and column group PL/SQL generated

There may be other rules that may come into play as well, but are not yet documented here.

## Explanation of spreadsheet columns

Some are self explanatory and will not be documented here.

### Compared To

This is the index that was compared to the index under examination.
Note: not all indexes appear in this report.

### Constraint Type

The type of constraint the index is supporting.

* U: Unique Constraint
* R: Foreign Key
* P: Primary Key
* NONE: none

### Redundant

If all of the columns in the index are 100% contained in the 'Compared To' index, and they are in the same order from the first column on, then the index is flagged as redundant ad as 'drop immediately'.

This is currently true even of indexes that known to have been used.

On reflection it may be a good idea to not set the 'drop immediately' flag if the index has been used.

### Column Dup%

When comparing the column list for 2 indexes, a percentage of duplication is calculated.

Given these 2 indexes:

* idx_1: c1,c2,c3,c4,c5
* idx_2: c1,c2,c3

The first 3 columns of idx_1 are duplicated in idx_2.

3/5*100 = 60

So there is 60% duplication of the columns of idx_1 when compared to idx_2.

It may be possible to drop the index. 
The default threshold in the script is 75%.


### Known Used

Index usage has been harvested from gv$sql_plan since 2017-04-18  
(currently it is 2017-05-03)

Indexes that have not appeared there are shown as Unused.


## To Do


* done - optionally output execution plans from gv$sql_plan
* done - optionally output execution plans from dba_hist_sql_plan
* --no-squash option for index-compare.pl  
  * check for current output files and do not overwrite
  * keep in mind the new files may have additional contents


### # Utilities

Read large directory entry tables when ls cannot.

getdents can be useful determine how many files are in the index-ddl directory when there are many files.

### ## getdents: show all directory entries

```text

  ./getdents [some directory]

~/oracle/utilities/getdents $ ./getdents
--------------- nread=296 ---------------
   i-node# file type    d_reclen                d_off d_name
   4460613 regular            40  1318648526085781404 getdents-terse
   4460611 directory          24  1911077624233088714 .git
   4459384 regular            32  1932872112554708992 README.md
   4459388 regular            32  4694681258015450928 getdents.c
   4459383 regular            32  4970382855881317507 getdents
   4460527 regular            40  7034733065521167176 getdents-terse.c
   4459382 directory          24  7122204098038305193 .
   4459381 directory          24  9223372036854775807 ..


```


### getdents-terse: show only inode and name for regular files only</h3>

```text

  ./getdents-terse [some directory]

4460613     getdents-terse
4459384     README.md
4459388     getdents.c
4459383     getdents
4460527     getdents-terse.c

```


### Command to create new binaries

The included binaries were built on Unbuntu 16 64bit and may or may not work as is.

```text

gcc -o getdents getdents.c

gcc -o getdents-terse getdents-terse.c

```

### Example usage

```text

index-compare: time ./getdents-terse column-group-ddl | wc -l
149696

real	0m0.201s
user	0m0.053s
sys	0m0.179s


index-compare: time ls -1 column-group-ddl | wc -l
149696

real	0m2.184s
user	0m1.327s
sys	0m0.219s

index-compare: time ./getdents-terse index-ddl | wc -l
332340

real	0m0.464s
user	0m0.140s
sys	0m0.380s
    
index-compare: time ls -1 index-ddl | wc -l
332340

real	0m2.382s
user	0m2.016s
sys	0m0.410s


```





