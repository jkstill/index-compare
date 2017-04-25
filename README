
== track index usage ==

###########################

-- Workflow

create the avail table:
   create-ct-index-table.sql

   this table just tracks index names that are logged in the output file of the next step
   populating this table is done via a later script

collect index stats from v$sql_plan:
   nohup vsql-idx.sh &

   change the iteration value to determine how long this will run
   runs every 5 minutes so ~ 288 times per day
    
monitor progress:
  -- current number of appearances in gv$sql_plan by an index
  cut -f5 -d, vsql-idx.csv| sort | uniq -c | sort -n | awk '{ if ($1 > 20) printf("%5d %s30\n", $1 ,$2) }'
  
  -- count of CT indexes that have so far appeared in gv$sql
  cut -f5 -d, vsql-idx.csv| sort -u | wc -l


insert into avail table
  ct-index-insert.sh
  
  this script calls ct-index-insert.pl
  the script can be run as many times as needed as new rows are inserted only if they exist
  not an efficient method, but ok for occasional use

check for potentially unused indexes
  unused-ct-indexes.sql

  this script ignores LOB indexes, and indexes with a _PK or _UK suffix

