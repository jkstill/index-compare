
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

<h4>create the avail table:</h4>
  <pre>
  create-ct-index-table.sql

  this table just tracks index names that are logged in the output file of the next step
  populating this table is done via a later script
  </pre>

<h4>collect index stats from v$sql_plan:</h4>
  <pre>
  nohup vsql-idx.sh &

  change the iteration value to determine how long this will run
  runs every 5 minutes so ~ 288 times per day
  </pre>
    
<h4>monitor progress:</h4>
  <pre>
  -- current number of appearances in gv$sql_plan by an index
  cut -f5 -d, vsql-idx.csv| sort | uniq -c | sort -n | awk '{ if ($1 > 20) printf("%5d %s30\n", $1 ,$2) }'
  
  -- count of schema indexes that have so far appeared in gv$sql
  cut -f5 -d, vsql-idx.csv| sort -u | wc -l
  </pre>


<h4>insert into avail table</h4>
  <pre>
  ct-index-insert.sh
  
  this script calls ct-index-insert.pl
  the script can be run as many times as needed as new rows are inserted only if they exist
  not an efficient method, but ok for occasional use
  </pre>

<h4>check for potentially unused indexes</h4>
  <pre>
  unused-ct-indexes.sql

  this script ignores LOB indexes, and indexes with a _PK or _UK suffix
  </pre>

<h4>analyze the schemas</h4>
  <pre>
  index-compare.pl analyzes indexes and reports where at least 75% of the leading columns are identical between 2 indexes
  <probably more to come for this>
  </pre>



