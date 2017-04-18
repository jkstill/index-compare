#!/bin/bash


: <<'JKS-DOC'

We do not have access to AWR (dba_hist-*) or ASH (v$active_session_history)

Statspack is running but at level 5, so no sql plan data

The Perl script vsql-idx.pl will collect data from v$sql_plan.

All indexes owned by CT that appear in v$sql_plan will be recorded in a file created by the script

Each iteration will check for new entries as of the previous timestamp

JKS-DOC

IDXHOME='/home/oracle/working/still/CR-1113105_indexes'

cd $IDXHOME || {
	echo
	echo $IDXHOME not found
	exit 1
}


unset ORAENV_ASK

PATH=/usr/local/bin:$PATH

. /usr/local/bin/oraenv <<< iotkdb

# run every 5 minutes
# do this for about a week

maxIterations=2100

while ( [[ $maxIterations > 0 ]] )
do

	$ORACLE_HOME/perl/bin/perl vsql-idx.pl
	echo Iteration: $maxIterations
	sleep 300

	(( maxIterations-- ))
done

